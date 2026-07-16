// Boost.Asio empty-ok HTTP/1.1 (standalone or Boost layout).
// Build: see build.sh

#include <boost/asio.hpp>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <utility>

namespace asio = boost::asio;
using tcp = asio::ip::tcp;

static const char RESP[] =
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK";

class Session : public std::enable_shared_from_this<Session> {
public:
  explicit Session(tcp::socket socket) : socket_(std::move(socket)) {}

  void start() { do_read(); }

private:
  void do_read() {
    auto self = shared_from_this();
    socket_.async_read_some(
        asio::buffer(data_, max_length),
        [this, self](boost::system::error_code ec, std::size_t /*n*/) {
          if (!ec) {
            do_write();
          }
        });
  }

  void do_write() {
    auto self = shared_from_this();
    asio::async_write(
        socket_, asio::buffer(RESP, sizeof(RESP) - 1),
        [this, self](boost::system::error_code ec, std::size_t /*n*/) {
          if (!ec) {
            do_read();
          }
        });
  }

  tcp::socket socket_;
  enum { max_length = 4096 };
  char data_[max_length];
};

class Server {
public:
  Server(asio::io_context &io, unsigned short port)
      : acceptor_(io, tcp::endpoint(tcp::v4(), port)) {
    do_accept();
  }

private:
  void do_accept() {
    acceptor_.async_accept(
        [this](boost::system::error_code ec, tcp::socket socket) {
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
    unsigned short port = 18080;
    if (const char *p = std::getenv("PORT")) {
      port = static_cast<unsigned short>(std::stoi(p));
    }
    asio::io_context io;
    Server s(io, port);
    std::cout << "asio empty-ok on 0.0.0.0:" << port << std::endl;
    io.run();
  } catch (std::exception &e) {
    std::cerr << "exception: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
