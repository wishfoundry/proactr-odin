// Size ladder + fortunes. Linux: BOOST_ASIO_HAS_IO_URING + DISABLE_EPOLL.
#include <boost/asio.hpp>
#include <sqlite3.h>

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace asio = boost::asio;
using tcp = asio::ip::tcp;

static std::string g_db_path = "/tmp/proactr-tfb.sqlite";
static std::string P_4K, P_64K, P_1M, P_4M;

static std::string make_payload(size_t n) {
  static const char *pat =
      "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF";
  std::string s;
  s.resize(n);
  for (size_t i = 0; i < n; ++i)
    s[i] = pat[i % 64];
  return s;
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

static std::string fortunes_html() {
  sqlite3 *db = nullptr;
  if (sqlite3_open_v2(g_db_path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr) !=
      SQLITE_OK)
    return "db open failed";
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
            [](const Fortune &a, const Fortune &b) { return a.message < b.message; });
  std::string html =
      "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>"
      "<tr><th>id</th><th>message</th></tr>";
  for (const auto &f : list) {
    html += "<tr><td>" + std::to_string(f.id) + "</td><td>" +
            html_escape(f.message) + "</td></tr>";
  }
  html += "</table></body></html>";
  return html;
}

static std::string http_response(const std::string &status, const std::string &ctype,
                                 const std::string &body) {
  return "HTTP/1.1 " + status + "\r\nServer: Asio\r\nContent-Type: " + ctype +
         "\r\nContent-Length: " + std::to_string(body.size()) +
         "\r\nConnection: keep-alive\r\n\r\n" + body;
}

class Session : public std::enable_shared_from_this<Session> {
public:
  explicit Session(tcp::socket socket) : socket_(std::move(socket)) {}
  void start() { do_read(); }

private:
  void do_read() {
    auto self = shared_from_this();
    socket_.async_read_some(
        asio::buffer(data_, max_length),
        [this, self](boost::system::error_code ec, std::size_t n) {
          if (ec)
            return;
          buf_.append(data_, n);
          auto pos = buf_.find("\r\n\r\n");
          if (pos == std::string::npos) {
            do_read();
            return;
          }
          std::string head = buf_.substr(0, pos);
          buf_.erase(0, pos + 4);
          std::string resp;
          if (head.find("GET /fortunes") != std::string::npos)
            resp = http_response("200 OK", "text/html; charset=utf-8",
                                 fortunes_html());
          else if (head.find("GET /s/4k") != std::string::npos)
            resp = http_response("200 OK", "text/plain", P_4K);
          else if (head.find("GET /s/64k") != std::string::npos)
            resp = http_response("200 OK", "text/plain", P_64K);
          else if (head.find("GET /s/1m") != std::string::npos)
            resp = http_response("200 OK", "text/plain", P_1M);
          else if (head.find("GET /s/4m") != std::string::npos)
            resp = http_response("200 OK", "text/plain", P_4M);
          else if (head.find("GET /plaintext") != std::string::npos ||
                   head.find("GET / HTTP") != std::string::npos)
            resp = http_response("200 OK", "text/plain", "Hello, World!");
          else
            resp = http_response("404 Not Found", "text/plain", "not found");
          auto sr = std::make_shared<std::string>(std::move(resp));
          asio::async_write(
              socket_, asio::buffer(*sr),
              [this, self, sr](boost::system::error_code wec, std::size_t) {
                if (!wec)
                  do_read();
              });
        });
  }

  tcp::socket socket_;
  enum { max_length = 8192 };
  char data_[max_length];
  std::string buf_;
};

class Server {
public:
  Server(asio::io_context &io, unsigned short port)
      : acceptor_(io, tcp::endpoint(tcp::v4(), port)) {
    do_accept();
  }

private:
  void do_accept() {
    acceptor_.async_accept([this](boost::system::error_code ec, tcp::socket socket) {
      if (!ec)
        std::make_shared<Session>(std::move(socket))->start();
      do_accept();
    });
  }
  tcp::acceptor acceptor_;
};

int main() {
  try {
    if (const char *p = std::getenv("DATABASE_PATH"))
      g_db_path = p;
    unsigned short port = 18080;
    if (const char *p = std::getenv("PORT"))
      port = static_cast<unsigned short>(std::stoi(p));
    P_4K = make_payload(4 * 1024);
    P_64K = make_payload(64 * 1024);
    P_1M = make_payload(1024 * 1024);
    P_4M = make_payload(4 * 1024 * 1024);
    asio::io_context io;
    Server s(io, port);
    std::cout << "asio tfb peer on 0.0.0.0:" << port << " db=" << g_db_path
              << " io=asio/io_uring" << std::endl;
    io.run();
  } catch (std::exception &e) {
    std::cerr << "exception: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
