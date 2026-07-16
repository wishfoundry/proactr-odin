// Plain text + HTML Asio peer with io_uring (Linux).
// Build: build.sh (defines BOOST_ASIO_HAS_IO_URING + BOOST_ASIO_DISABLE_EPOLL).
//
// Fortunes: SQLite via sqlite3 C API. Network path is Asio io_uring.

// Flags also passed on the compiler command line (build.sh).
#include <boost/asio.hpp>
#include <sqlite3.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace asio = boost::asio;
using tcp = asio::ip::tcp;

struct Fortune {
  int id;
  std::string message;
};

static std::string g_db_path = "/tmp/proactr-tfb.sqlite";

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
      SQLITE_OK) {
    return "db open failed";
  }
  sqlite3_busy_timeout(db, 5000);
  std::vector<Fortune> list;
  list.reserve(16);
  const char *sql = "SELECT id, message FROM fortune";
  sqlite3_stmt *stmt = nullptr;
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) == SQLITE_OK) {
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

  std::string html;
  html.reserve(2048);
  html += "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>";
  html += "<tr><th>id</th><th>message</th></tr>";
  for (const auto &f : list) {
    html += "<tr><td>";
    html += std::to_string(f.id);
    html += "</td><td>";
    html += html_escape(f.message);
    html += "</td></tr>";
  }
  html += "</table></body></html>";
  return html;
}

static std::string http_response(const std::string &status, const std::string &ctype,
                                 const std::string &body) {
  std::string out;
  out.reserve(body.size() + 160);
  out += "HTTP/1.1 ";
  out += status;
  out += "\r\nServer: Asio\r\nContent-Type: ";
  out += ctype;
  out += "\r\nContent-Length: ";
  out += std::to_string(body.size());
  out += "\r\nConnection: keep-alive\r\n\r\n";
  out += body;
  return out;
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
          for (;;) {
            auto pos = buf_.find("\r\n\r\n");
            if (pos == std::string::npos)
              break;
            std::string head = buf_.substr(0, pos);
            buf_.erase(0, pos + 4);
            std::string resp;
            if (head.rfind("GET /fortunes", 0) == 0 ||
                head.find("GET /fortunes ") != std::string::npos) {
              resp = http_response("200 OK", "text/html; charset=utf-8",
                                   fortunes_html());
            } else if (head.rfind("GET /plaintext", 0) == 0 ||
                       head.find("GET /plaintext ") != std::string::npos ||
                       head.rfind("GET / ", 0) == 0 || head.rfind("GET / HTTP", 0) == 0) {
              resp = http_response("200 OK", "text/plain", "Hello, World!");
            } else {
              resp = http_response("404 Not Found", "text/plain", "not found");
            }
            auto sr = std::make_shared<std::string>(std::move(resp));
            asio::async_write(
                socket_, asio::buffer(*sr),
                [this, self, sr](boost::system::error_code wec, std::size_t) {
                  if (!wec)
                    do_read();
                });
            return; // one response then wait for write before more reads
          }
          do_read();
        });
  }

  tcp::socket socket_;
  enum { max_length = 4096 };
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
      if (!ec) {
        std::make_shared<Session>(std::move(socket))->start();
      }
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

    asio::io_context io;
    Server s(io, port);
    std::cout << "asio tfb peer on 0.0.0.0:" << port << " db=" << g_db_path
              << " io=asio/io_uring (HAS_IO_URING+DISABLE_EPOLL)" << std::endl;
    io.run();
  } catch (std::exception &e) {
    std::cerr << "exception: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
