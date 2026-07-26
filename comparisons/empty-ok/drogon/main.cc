#include <drogon/drogon.h>
#include <cstdlib>
#include <iostream>
#include <string>

int main() {
  uint16_t port = 18080;
  if (const char *p = std::getenv("PORT")) {
    port = static_cast<uint16_t>(std::stoi(p));
  }
  // Default 1 (was 0 = hardware concurrency — unfair vs WORKERS-aware peers).
  size_t workers = 1;
  if (const char *w = std::getenv("WORKERS")) {
    workers = static_cast<size_t>(std::stoul(w));
    if (workers < 1) {
      workers = 1;
    }
  }

  std::cout << "drogon empty-ok on 0.0.0.0:" << port << " workers=" << workers
            << std::endl;

  drogon::app()
      .registerHandler(
          "/",
          [](const drogon::HttpRequestPtr &,
             std::function<void(const drogon::HttpResponsePtr &)> &&cb) {
            auto resp = drogon::HttpResponse::newHttpResponse();
            resp->setBody("OK");
            cb(resp);
          },
          {drogon::Get})
      .registerHandler(
          "/health",
          [](const drogon::HttpRequestPtr &,
             std::function<void(const drogon::HttpResponsePtr &)> &&cb) {
            auto resp = drogon::HttpResponse::newHttpResponse();
            resp->setBody("ok");
            cb(resp);
          },
          {drogon::Get})
      .setLogLevel(trantor::Logger::kWarn)
      .addListener("0.0.0.0", port)
      .setThreadNum(workers)
      .run();
  return 0;
}
