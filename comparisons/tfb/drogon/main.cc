// Plain text + HTML Drogon peer (SQLite fortunes, no JSON).
#include <drogon/drogon.h>
#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using namespace drogon;

struct Fortune {
  int id;
  std::string message;
};

static std::string html_escape(const std::string &s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s) {
    switch (c) {
    case '&':
      out += "&amp;";
      break;
    case '<':
      out += "&lt;";
      break;
    case '>':
      out += "&gt;";
      break;
    case '"':
      out += "&quot;";
      break;
    case '\'':
      out += "&#39;";
      break;
    default:
      out += c;
      break;
    }
  }
  return out;
}

int main() {
  const char *db = std::getenv("DATABASE_PATH");
  std::string dbPath = db ? db : "/tmp/proactr-tfb.sqlite";
  uint16_t port = 18080;
  if (const char *p = std::getenv("PORT"))
    port = static_cast<uint16_t>(std::stoi(p));
  size_t workers = 1;
  if (const char *w = std::getenv("WORKERS"))
    workers = static_cast<size_t>(std::stoul(w));

  app().createDbClient("sqlite3", dbPath, 0, "", "", "",
                       std::max<size_t>(workers * 2, 4));

  app().registerHandler(
      "/plaintext",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        auto resp = HttpResponse::newHttpResponse();
        resp->setContentTypeCode(CT_TEXT_PLAIN);
        resp->setBody("Hello, World!");
        resp->addHeader("Server", "Drogon");
        cb(resp);
      },
      {Get});

  app().registerHandler(
      "/fortunes",
      [](const HttpRequestPtr &,
         std::function<void(const HttpResponsePtr &)> &&cb) {
        auto client = app().getDbClient();
        *client << "SELECT id, message FROM fortune" >>
            [cb = std::move(cb)](const Result &r) mutable {
              std::vector<Fortune> list;
              list.reserve(r.size() + 1);
              for (const auto &row : r) {
                list.push_back(
                    Fortune{row["id"].as<int>(), row["message"].as<std::string>()});
              }
              list.push_back(
                  Fortune{0, "Additional fortune added at request time."});
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
              auto resp = HttpResponse::newHttpResponse();
              resp->setContentTypeCode(CT_TEXT_HTML);
              resp->setBody(oss.str());
              resp->addHeader("Server", "Drogon");
              cb(resp);
            } >>
            [cb](const DrogonDbException &e) {
              auto resp = HttpResponse::newHttpResponse();
              resp->setStatusCode(k500InternalServerError);
              resp->setBody(e.base().what());
              cb(resp);
            };
      },
      {Get});

  std::cout << "drogon tfb peer on 0.0.0.0:" << port << " db=" << dbPath
            << std::endl;
  app()
      .setLogLevel(trantor::Logger::kWarn)
      .addListener("0.0.0.0", port)
      .setThreadNum(workers)
      .run();
  return 0;
}
