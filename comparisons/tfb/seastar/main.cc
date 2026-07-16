// Seastar TFB peer: size ladder + fortunes (posix / kernel sockets, no DPDK).
#include <algorithm>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <sqlite3.h>

#include <seastar/core/app-template.hh>
#include <seastar/core/condition-variable.hh>
#include <seastar/core/reactor.hh>
#include <seastar/core/seastar.hh>
#include <seastar/core/thread.hh>
#include <seastar/http/function_handlers.hh>
#include <seastar/http/httpd.hh>
#include <seastar/net/inet_address.hh>

namespace bpo = boost::program_options;
using namespace seastar;
using namespace httpd;

static std::string g_db_path = "/tmp/proactr-tfb.sqlite";
static sstring P_PLAIN = "Hello, World!";
static sstring P_4K, P_64K, P_1M, P_4M;

static sstring make_payload(size_t n) {
  static const char *pat =
      "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF";
  std::string s(n, 'x');
  for (size_t i = 0; i < n; ++i)
    s[i] = pat[i % 64];
  return sstring(s);
}

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

static sstring fortunes_html() {
  sqlite3 *db = nullptr;
  if (sqlite3_open_v2(g_db_path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr) !=
      SQLITE_OK) {
    return sstring("db open failed");
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
  oss << "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>"
         "<tr><th>id</th><th>message</th></tr>";
  for (const auto &f : list) {
    oss << "<tr><td>" << f.id << "</td><td>" << html_escape(f.message)
        << "</td></tr>";
  }
  oss << "</table></body></html>";
  return sstring(oss.str());
}

static void set_routes(routes &r) {
  auto add_plain = [&](const char *path, const sstring *body) {
    r.add(operation_type::GET, url(path),
          new function_handler([body](const_req) { return *body; }, "txt"));
  };
  add_plain("/plaintext", &P_PLAIN);
  add_plain("/s/4k", &P_4K);
  add_plain("/s/64k", &P_64K);
  add_plain("/s/1m", &P_1M);
  add_plain("/s/4m", &P_4M);
  r.add(operation_type::GET, url("/fortunes"),
        new function_handler([](const_req) { return fortunes_html(); }, "html"));
}

class stop_signal {
  bool _caught = false;
  condition_variable _cv;

public:
  stop_signal() {
    engine().handle_signal(SIGINT, [this] { signaled(); });
    engine().handle_signal(SIGTERM, [this] { signaled(); });
  }
  void signaled() {
    if (!_caught) {
      _caught = true;
      _cv.broadcast();
    }
  }
  future<> wait() {
    return _cv.wait([this] { return _caught; });
  }
};

int main(int ac, char **av) {
  app_template app;
  app.add_options()("port", bpo::value<uint16_t>()->default_value(18080),
                    "HTTP port")(
      "db", bpo::value<std::string>()->default_value("/tmp/proactr-tfb.sqlite"),
      "SQLite path");

  return app.run(ac, av, [&] {
    return seastar::async([&] {
      stop_signal stop;
      auto &&config = app.configuration();
      uint16_t port = config["port"].as<uint16_t>();
      g_db_path = config["db"].as<std::string>();
      if (const char *e = std::getenv("PORT"))
        port = static_cast<uint16_t>(std::stoi(e));
      if (const char *e = std::getenv("DATABASE_PATH"))
        g_db_path = e;

      P_4K = make_payload(4 * 1024);
      P_64K = make_payload(64 * 1024);
      P_1M = make_payload(1024 * 1024);
      P_4M = make_payload(4 * 1024 * 1024);

      auto server = std::make_unique<http_server_control>();
      server->start("tfb").get();
      server->set_routes(set_routes).get();
      server->listen(socket_address{net::inet_address{}, port}).get();

      std::cout << "seastar tfb peer on 0.0.0.0:" << port << " db=" << g_db_path
                << " io=seastar/posix shards=" << smp::count << std::endl;

      stop.wait().get();
      server->stop().get();
      return 0;
    });
  });
}
