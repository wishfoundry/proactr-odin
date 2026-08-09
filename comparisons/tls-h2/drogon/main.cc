// TLS peer for comparisons/tls-h2. Drogon/trantor = epoll + OpenSSL.
// HTTP/2: Drogon is primarily HTTP/1.1; h2 cells may be N/A if ALPN≠h2.
// Instrumentation: GET /_matrix/stats (reqs + body bytes).
#include <drogon/drogon.h>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <string>

using namespace drogon;

static std::atomic<uint64_t> g_reqs{0}, g_bytes{0};

static std::string make_payload(size_t n) {
  static const char *pat =
      "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF";
  std::string s(n, 'x');
  for (size_t i = 0; i < n; ++i)
    s[i] = pat[i % 64];
  return s;
}

static std::string P_4K, P_64K, P_1M;
static const char *PLAIN = "Hello, World!";
static const char *SSE = "event: ping\ndata: 1\n\nevent: ping\ndata: 2\n\n";

static void note(size_t n) {
  g_reqs.fetch_add(1, std::memory_order_relaxed);
  g_bytes.fetch_add(n, std::memory_order_relaxed);
}

static void plain(const std::string &body,
                  std::function<void(const HttpResponsePtr &)> &&cb) {
  note(body.size());
  auto resp = HttpResponse::newHttpResponse();
  resp->setStatusCode(k200OK);
  resp->setContentTypeCode(CT_TEXT_PLAIN);
  resp->addHeader("Server", "drogon");
  resp->setBody(body);
  cb(resp);
}

static void plain_cstr(const char *body, size_t n,
                       std::function<void(const HttpResponsePtr &)> &&cb) {
  note(n);
  auto resp = HttpResponse::newHttpResponse();
  resp->setStatusCode(k200OK);
  resp->setContentTypeCode(CT_TEXT_PLAIN);
  resp->addHeader("Server", "drogon");
  resp->setBody(std::string(body, n));
  cb(resp);
}

int main() {
  int port = 18443;
  int workers = 8;
  if (const char *p = std::getenv("PORT"))
    port = std::atoi(p);
  if (const char *w = std::getenv("WORKERS"))
    workers = std::atoi(w);
  std::string cert =
      std::getenv("CERT_FILE") ? std::getenv("CERT_FILE") : "certs/cert.pem";
  std::string key =
      std::getenv("KEY_FILE") ? std::getenv("KEY_FILE") : "certs/key.pem";

  P_4K = make_payload(4 * 1024);
  P_64K = make_payload(64 * 1024);
  P_1M = make_payload(1024 * 1024);

  app().registerHandler(
      "/plaintext",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        plain_cstr(PLAIN, 13, std::move(cb));
      },
      {Get});
  app().registerHandler(
      "/api/tiny",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        plain_cstr(PLAIN, 13, std::move(cb));
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
      "/sse",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        note(42);
        auto resp = HttpResponse::newHttpResponse();
        resp->setStatusCode(k200OK);
        resp->setContentTypeString("text/event-stream");
        resp->addHeader("Server", "drogon");
        resp->setBody(SSE);
        cb(resp);
      },
      {Get});
  app().registerHandler(
      "/_matrix/stats",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "peer=drogon\nreqs=%llu\nbytes=%llu\ntls=openssl\nio=trantor/"
                 "epoll\nh2=limited_or_none\n",
                 (unsigned long long)g_reqs.load(std::memory_order_relaxed),
                 (unsigned long long)g_bytes.load(std::memory_order_relaxed));
        auto resp = HttpResponse::newHttpResponse();
        resp->setStatusCode(k200OK);
        resp->setContentTypeCode(CT_TEXT_PLAIN);
        resp->setBody(buf);
        cb(resp);
      },
      {Get});
  app().registerHandler(
      "/_matrix/reset",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        g_reqs.store(0, std::memory_order_relaxed);
        g_bytes.store(0, std::memory_order_relaxed);
        auto resp = HttpResponse::newHttpResponse();
        resp->setStatusCode(k200OK);
        resp->setBody("ok\n");
        cb(resp);
      },
      {Get, Post});

  std::cout << "drogon tls-h2 on 0.0.0.0:" << port << " workers=" << workers
            << " tls=openssl cert=" << cert
            << " io=trantor/epoll alpn=listener_ssl"
            << " instrument=reqs+bytes h2=not_product_claimed" << std::endl;

  // useSSL=true; cert/key paths. Drogon HTTP/2 is not a product claim here.
  app()
      .setLogLevel(trantor::Logger::kWarn)
      .addListener("0.0.0.0", port, true, cert, key)
      .setThreadNum(workers)
      .run();
  return 0;
}
