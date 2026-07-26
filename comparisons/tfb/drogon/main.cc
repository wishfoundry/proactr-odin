// Size ladder + fortunes. Drogon/trantor = epoll (not io_uring).
// Fortunes uses sqlite3 C API (same DB file as other peers) to avoid DbClient
// path quirks; network path remains Drogon/trantor.
#include <drogon/drogon.h>
#include <sqlite3.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <x86intrin.h>

using namespace drogon;

// PHASE_STATS=1: aggregate cycles for AOP stages (parse≈up to pre-routing not
// included; we time handle + build + pre-send). Parse is measured via
// (pre-routing - connection read) is hard; we report:
//   handle = pre-handling → post-handling (controller)
//   build  = inside plain() setBody+cb only
//   full_handler = pre-handling → pre-sending (includes response creation)
static std::atomic<uint64_t> g_n{0}, g_handle_cyc{0}, g_build_cyc{0},
    g_presend_gap_cyc{0};
static thread_local uint64_t tl_pre_handle = 0;
static thread_local uint64_t tl_post_handle = 0;

static inline uint64_t rdtsc() { return __rdtsc(); }

static void phase_maybe_log() {
  uint64_t n = g_n.load(std::memory_order_relaxed);
  if (n == 0 || (n % 50000) != 0)
    return;
  uint64_t h = g_handle_cyc.load(std::memory_order_relaxed);
  uint64_t b = g_build_cyc.load(std::memory_order_relaxed);
  uint64_t g = g_presend_gap_cyc.load(std::memory_order_relaxed);
  std::cerr << "PHASE drogon n=" << n << " cyc/req: handle=" << (h / n)
            << " build=" << (b / n) << " post_handle_to_presend=" << (g / n)
            << std::endl;
}

static std::string g_db_path = "/tmp/proactr-tfb.sqlite";

static std::string make_payload(size_t n) {
  static const char *pat =
      "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF";
  std::string s(n, 'x');
  for (size_t i = 0; i < n; ++i)
    s[i] = pat[i % 64];
  return s;
}

static std::string P_4K, P_64K, P_1M, P_4M;

struct Fortune {
  int id;
  std::string message;
};

static std::string html_escape(const std::string &s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s) {
    switch (c) {
    case '&': out += "&amp;"; break;
    case '<': out += "&lt;"; break;
    case '>': out += "&gt;"; break;
    case '"': out += "&quot;"; break;
    case '\'': out += "&#39;"; break;
    default: out += c; break;
    }
  }
  return out;
}

static void plain(const std::string &body,
                  std::function<void(const HttpResponsePtr &)> &&cb) {
  uint64_t t0 = 0;
  if (std::getenv("PHASE_STATS"))
    t0 = rdtsc();
  auto resp = HttpResponse::newHttpResponse();
  resp->setContentTypeCode(CT_TEXT_PLAIN);
  resp->setBody(body);
  resp->addHeader("Server", "Drogon");
  if (std::getenv("PHASE_STATS") && t0) {
    g_build_cyc.fetch_add(rdtsc() - t0, std::memory_order_relaxed);
  }
  cb(resp);
}

static std::string fortunes_html() {
  sqlite3 *db = nullptr;
  if (sqlite3_open_v2(g_db_path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr) !=
      SQLITE_OK) {
    return "db open failed";
  }
  sqlite3_busy_timeout(db, 5000);
  std::vector<Fortune> list;
  sqlite3_stmt *stmt = nullptr;
  if (sqlite3_prepare_v2(db, "SELECT id, message FROM fortune", -1, &stmt,
                         nullptr) == SQLITE_OK) {
    while (sqlite3_step(stmt) == SQLITE_ROW) {
      Fortune f;
      f.id = sqlite3_column_int(stmt, 0);
      const unsigned char *m = sqlite3_column_text(stmt, 1);
      f.message = m ? reinterpret_cast<const char *>(m) : "";
      list.push_back(std::move(f));
    }
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  list.push_back(Fortune{0, "Additional fortune added at request time."});
  std::sort(list.begin(), list.end(),
            [](const Fortune &a, const Fortune &b) {
              return a.message < b.message;
            });
  std::ostringstream oss;
  oss << "<!DOCTYPE html><html><head><title>Fortunes</title></head>"
         "<body><table><tr><th>id</th><th>message</th></tr>";
  for (const auto &f : list) {
    oss << "<tr><td>" << f.id << "</td><td>" << html_escape(f.message)
        << "</td></tr>";
  }
  oss << "</table></body></html>";
  return oss.str();
}

int main() {
  const char *db = std::getenv("DATABASE_PATH");
  if (db)
    g_db_path = db;
  uint16_t port = 18080;
  if (const char *p = std::getenv("PORT"))
    port = static_cast<uint16_t>(std::stoi(p));
  size_t workers = 1;
  if (const char *w = std::getenv("WORKERS"))
    workers = static_cast<size_t>(std::stoul(w));

  P_4K = make_payload(4 * 1024);
  P_64K = make_payload(64 * 1024);
  P_1M = make_payload(1024 * 1024);
  P_4M = make_payload(4 * 1024 * 1024);

  app().registerHandler(
      "/plaintext",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        plain("Hello, World!", std::move(cb));
      },
      {Get});
  app().registerHandler(
      "/s/4k",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        plain(P_4K, std::move(cb));
      },
      {Get});
  app().registerHandler(
      "/s/64k",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        plain(P_64K, std::move(cb));
      },
      {Get});
  app().registerHandler(
      "/s/1m",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        plain(P_1M, std::move(cb));
      },
      {Get});
  app().registerHandler(
      "/s/4m",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        plain(P_4M, std::move(cb));
      },
      {Get});

  app().registerHandler(
      "/fortunes",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        auto resp = HttpResponse::newHttpResponse();
        resp->setContentTypeCode(CT_TEXT_HTML);
        resp->setBody(fortunes_html());
        resp->addHeader("Server", "Drogon");
        cb(resp);
      },
      {Get});

  if (std::getenv("PHASE_STATS")) {
    app().registerPreHandlingAdvice([](const HttpRequestPtr &) {
      tl_pre_handle = rdtsc();
    });
    app().registerPostHandlingAdvice(
        [](const HttpRequestPtr &, const HttpResponsePtr &) {
          tl_post_handle = rdtsc();
          if (tl_pre_handle) {
            g_handle_cyc.fetch_add(tl_post_handle - tl_pre_handle,
                                   std::memory_order_relaxed);
          }
        });
    app().registerPreSendingAdvice(
        [](const HttpRequestPtr &, const HttpResponsePtr &) {
          if (tl_post_handle) {
            g_presend_gap_cyc.fetch_add(rdtsc() - tl_post_handle,
                                        std::memory_order_relaxed);
            g_n.fetch_add(1, std::memory_order_relaxed);
            phase_maybe_log();
          }
          tl_pre_handle = 0;
          tl_post_handle = 0;
        });
    std::cerr << "PHASE_STATS=1 (handle/build/pre-send gap via AOP)"
              << std::endl;
  }

  std::cout << "drogon tfb peer on 0.0.0.0:" << port << " db=" << g_db_path
            << " io=trantor/epoll workers=" << workers << std::endl;
  app()
      .setLogLevel(trantor::Logger::kWarn)
      .addListener("0.0.0.0", port)
      .setThreadNum(workers)
      .run();
  return 0;
}
