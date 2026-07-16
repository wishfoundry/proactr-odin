#include <drogon/drogon.h>
#include <cstdlib>
#include <string>

int main() {
  uint16_t port = 18080;
  if (const char *p = std::getenv("PORT")) {
    port = static_cast<uint16_t>(std::stoi(p));
  }

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
      .setThreadNum(0) // 0 = hardware concurrency
      .run();
  return 0;
}
