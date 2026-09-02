#include <coyote/cThread.hpp>
#include <qshell/qshell_abi_generated.hpp>

#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>

namespace {

constexpr std::uint8_t request_write = 1;
constexpr std::uint8_t request_read = 2;
constexpr std::size_t beat_bytes = ::qshell::abi::beat_bytes;
constexpr std::size_t header_bytes = ::qshell::abi::header_bytes;
constexpr std::size_t mbq_payload_bytes = 64;
constexpr std::size_t default_continuation_bytes =
    header_bytes + mbq_payload_bytes - beat_bytes;

std::uint32_t load_u32(const std::uint8_t *bytes) {
  std::uint32_t value = 0;
  std::memcpy(&value, bytes, sizeof(value));
  return value;
}

std::uint64_t load_u64(std::istream &stream) {
  std::array<std::uint8_t, 8> bytes{};
  stream.read(reinterpret_cast<char *>(bytes.data()), bytes.size());
  std::uint64_t value = 0;
  std::memcpy(&value, bytes.data(), sizeof(value));
  return value;
}

void store_u64(std::ostream &stream, std::uint64_t value) {
  std::array<std::uint8_t, 8> bytes{};
  std::memcpy(bytes.data(), &value, sizeof(value));
  stream.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
}

std::uint64_t low_keep(std::size_t bytes) {
  return bytes == beat_bytes ? std::numeric_limits<std::uint64_t>::max()
                     : (std::uint64_t{1} << bytes) - 1;
}

std::size_t valid_bytes(std::uint64_t keep) {
  if (keep == std::numeric_limits<std::uint64_t>::max()) {
    return beat_bytes;
  }
  std::size_t count = 0;
  while ((keep & 1U) != 0) {
    ++count;
    keep >>= 1U;
  }
  if (keep != 0 || count == 0) {
    throw std::runtime_error("keep must be one non-empty contiguous low-lane mask");
  }
  return count;
}

class bridge {
public:
  bridge(std::int32_t vfpga_id, std::chrono::milliseconds timeout,
         std::size_t expected_continuation)
      : thread_(vfpga_id, getpid()), timeout_(timeout),
        expected_continuation_(expected_continuation), tx_open_(false),
        cached_rx_valid_(false), cached_rx_bytes_(0) {
    if (expected_continuation_ == 0 || expected_continuation_ > beat_bytes) {
      throw std::runtime_error("response continuation must contain 1..64 bytes");
    }
    memory_ = reinterpret_cast<std::uint8_t *>(
        thread_.getMem({coyote::CoyoteAllocType::HPF, 2 * beat_bytes}));
    if (memory_ == nullptr) {
      throw std::runtime_error("failed to allocate Coyote huge-page buffer");
    }
  }

  void write_beat(const std::array<std::uint8_t, beat_bytes> &data,
                  std::uint64_t keep, bool last) {
    const auto bytes = valid_bytes(keep);
    if (!tx_open_) {
      if (bytes != beat_bytes || last) {
        throw std::runtime_error("first QShell beat must be full and non-final");
      }
      thread_.clearCompleted();
      tx_open_ = true;
    } else if (!last) {
      throw std::runtime_error("MicroBlossom QShell record has more than two beats");
    }

    std::memcpy(memory_, data.data(), bytes);
    coyote::localSg sg = {.addr = memory_,
                          .len = static_cast<std::uint32_t>(bytes),
                          .stream = 1};
    // Coyote names transfers from host memory into the vFPGA LOCAL_READ.
    thread_.invoke(coyote::CoyoteOper::LOCAL_READ, sg, last);
    if (last) {
      wait_for(coyote::CoyoteOper::LOCAL_READ);
      tx_open_ = false;
    }
  }

  std::array<std::uint8_t, beat_bytes> read_beat(std::uint64_t &keep,
                                                 bool &last) {
    if (cached_rx_valid_) {
      std::array<std::uint8_t, beat_bytes> result{};
      std::memcpy(result.data(), memory_ + beat_bytes, beat_bytes);
      keep = low_keep(cached_rx_bytes_);
      last = true;
      cached_rx_valid_ = false;
      return result;
    }

    std::memset(memory_, 0, 2 * beat_bytes);
    coyote::localSg first = {.addr = memory_, .len = beat_bytes, .stream = 1};
    coyote::localSg second = {
        .addr = memory_ + beat_bytes,
        .len = static_cast<std::uint32_t>(expected_continuation_),
        .stream = 1};
    thread_.clearCompleted();
    // Coyote names transfers from the vFPGA into host memory LOCAL_WRITE.
    thread_.invoke(coyote::CoyoteOper::LOCAL_WRITE, first, false);
    thread_.invoke(coyote::CoyoteOper::LOCAL_WRITE, second, true);
    wait_for(coyote::CoyoteOper::LOCAL_WRITE);

    if (load_u32(memory_ + ::qshell::abi::offset::magic) !=
            ::qshell::abi::magic ||
        memory_[::qshell::abi::offset::abi_version] != ::qshell::abi::version ||
        load_u32(memory_ + ::qshell::abi::offset::payload_bytes) <=
            beat_bytes - header_bytes) {
      throw std::runtime_error("expected a multi-beat current-QSH2 response");
    }
    const auto payload_bytes =
        load_u32(memory_ + ::qshell::abi::offset::payload_bytes);
    const auto continuation = payload_bytes - (beat_bytes - header_bytes);
    if (continuation != expected_continuation_) {
      throw std::runtime_error("QShell response continuation length mismatch");
    }
    cached_rx_bytes_ = continuation;
    cached_rx_valid_ = true;

    std::array<std::uint8_t, beat_bytes> result{};
    std::memcpy(result.data(), memory_, beat_bytes);
    keep = std::numeric_limits<std::uint64_t>::max();
    last = false;
    return result;
  }

private:
  coyote::cThread thread_;
  std::chrono::milliseconds timeout_;
  std::uint8_t *memory_;
  std::size_t expected_continuation_;
  bool tx_open_;
  bool cached_rx_valid_;
  std::size_t cached_rx_bytes_;

  void wait_for(coyote::CoyoteOper operation) {
    const auto start = std::chrono::steady_clock::now();
    while (thread_.checkCompleted(operation) != 1) {
      if (std::chrono::steady_clock::now() - start > timeout_) {
        throw std::runtime_error("timed out waiting for Coyote transfer completion");
      }
      std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
  }
};

void write_ok() {
  std::cout.put(0);
  std::cout.flush();
}

void write_error(const std::string &message) {
  std::cout.put(1);
  const auto size = static_cast<std::uint32_t>(message.size());
  std::cout.write(reinterpret_cast<const char *>(&size), sizeof(size));
  std::cout.write(message.data(), message.size());
  std::cout.flush();
}

int self_test() {
  if (valid_bytes(low_keep(default_continuation_bytes)) !=
          default_continuation_bytes ||
      valid_bytes(~std::uint64_t{0}) != beat_bytes) {
    return 1;
  }
  try {
    (void)valid_bytes(0x5);
    return 1;
  } catch (const std::runtime_error &) {
  }
  std::cout << "MICROBLOSSOM_QSHELL_COYOTE_BRIDGE_PASS\n";
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--self-test") {
    return self_test();
  }

  std::int32_t vfpga_id = 0;
  std::chrono::milliseconds timeout{1000};
  std::size_t continuation_bytes = default_continuation_bytes;
  for (int index = 1; index < argc; ++index) {
    const std::string argument(argv[index]);
    if (argument == "--vfpga" && index + 1 < argc) {
      vfpga_id = std::stoi(argv[++index]);
    } else if (argument == "--timeout-ms" && index + 1 < argc) {
      timeout = std::chrono::milliseconds(std::stoul(argv[++index]));
    } else if (argument == "--continuation-bytes" && index + 1 < argc) {
      continuation_bytes = std::stoul(argv[++index]);
    } else {
      std::cerr << "usage: " << argv[0]
                << " [--vfpga ID] [--timeout-ms MS]"
                   " [--continuation-bytes BYTES] [--self-test]\n";
      return 2;
    }
  }

  try {
    bridge link(vfpga_id, timeout, continuation_bytes);
    while (true) {
      const auto request = std::cin.get();
      if (request == std::char_traits<char>::eof()) {
        return 0;
      }
      try {
        if (request == request_write) {
          const bool last = std::cin.get() != 0;
          const auto keep = load_u64(std::cin);
          std::array<std::uint8_t, beat_bytes> data{};
          std::cin.read(reinterpret_cast<char *>(data.data()), data.size());
          if (!std::cin) {
            throw std::runtime_error("truncated write request");
          }
          link.write_beat(data, keep, last);
          write_ok();
        } else if (request == request_read) {
          std::uint64_t keep = 0;
          bool last = false;
          const auto data = link.read_beat(keep, last);
          write_ok();
          std::cout.put(last ? 1 : 0);
          store_u64(std::cout, keep);
          std::cout.write(reinterpret_cast<const char *>(data.data()), data.size());
          std::cout.flush();
        } else {
          throw std::runtime_error("unknown bridge request");
        }
      } catch (const std::exception &error) {
        write_error(error.what());
      }
    }
  } catch (const std::exception &error) {
    std::cerr << "microblossom QShell Coyote bridge: " << error.what() << '\n';
    return 1;
  }
}
