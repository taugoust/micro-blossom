#include <coyote/cThread.hpp>
#include <qshell/qshell_abi_generated.hpp>

#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

constexpr std::uint8_t request_write = 1;
constexpr std::uint8_t request_read = 2;
constexpr std::size_t beat_bytes = ::qshell::abi::beat_bytes;
constexpr std::size_t header_bytes = ::qshell::abi::header_bytes;
constexpr std::size_t packet_storage_bytes = 4096;
constexpr std::size_t max_packet_beats = packet_storage_bytes / beat_bytes;
constexpr std::size_t mbq_payload_bytes = 64;
constexpr std::size_t default_response_bytes = header_bytes + mbq_payload_bytes;

static_assert(beat_bytes == 64);
static_assert(packet_storage_bytes == max_packet_beats * beat_bytes);

struct packet_shape {
  std::size_t bytes;
  std::size_t beats;
  std::size_t final_bytes;
};

std::uint16_t load_u16(const std::uint8_t *bytes) {
  std::uint16_t value = 0;
  std::memcpy(&value, bytes, sizeof(value));
  return value;
}

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

void store_u16(std::uint8_t *bytes, std::uint16_t value) {
  std::memcpy(bytes, &value, sizeof(value));
}

void store_u32(std::uint8_t *bytes, std::uint32_t value) {
  std::memcpy(bytes, &value, sizeof(value));
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

packet_shape shape_for_bytes(std::size_t bytes) {
  if (bytes <= header_bytes || bytes > packet_storage_bytes) {
    throw std::runtime_error("QShell packet exceeds the 4096-byte provider store");
  }
  const auto beats = (bytes + beat_bytes - 1) / beat_bytes;
  if (beats == 0 || beats > max_packet_beats) {
    throw std::runtime_error("QShell packet exceeds the 64-beat provider bound");
  }
  return {.bytes = bytes,
          .beats = beats,
          .final_bytes = bytes - (beats - 1) * beat_bytes};
}

packet_shape shape_from_header(const std::uint8_t *first,
                               std::size_t first_valid_bytes) {
  if (first_valid_bytes < header_bytes ||
      load_u32(first + ::qshell::abi::offset::magic) != ::qshell::abi::magic ||
      first[::qshell::abi::offset::abi_version] != ::qshell::abi::version ||
      load_u16(first + ::qshell::abi::offset::header_bytes) != header_bytes ||
      load_u16(first + ::qshell::abi::offset::reserved) != 0) {
    throw std::runtime_error("invalid current-QSH2 header");
  }
  const auto payload_bytes =
      load_u32(first + ::qshell::abi::offset::payload_bytes);
  if (payload_bytes > packet_storage_bytes - header_bytes) {
    throw std::runtime_error("QShell payload exceeds the provider packet store");
  }
  return shape_for_bytes(header_bytes + payload_bytes);
}

bool same_shape(const packet_shape &left, const packet_shape &right) {
  return left.bytes == right.bytes && left.beats == right.beats &&
         left.final_bytes == right.final_bytes;
}

packet_shape accepted_response_shape(const std::uint8_t *first,
                                     const packet_shape &normal) {
  const auto actual = shape_from_header(first, beat_bytes);
  const auto record_class = first[::qshell::abi::offset::record_class];
  if (record_class ==
          static_cast<std::uint8_t>(::qshell::abi::record_class::correction) &&
      same_shape(actual, normal)) {
    return actual;
  }
  throw std::runtime_error(
      "production bridge accepts only the fixed-length correction response");
}

template <typename Submit, typename AwaitCompletion>
packet_shape receive_fixed_response(std::uint8_t *staging,
                                    const packet_shape &normal, Submit submit,
                                    AwaitCompletion await_completion) {
  submit(staging, normal.bytes);
  await_completion();
  return accepted_response_shape(staging, normal);
}

class packet_assembler {
public:
  std::optional<std::vector<std::uint8_t>>
  push(const std::array<std::uint8_t, beat_bytes> &data, std::uint64_t keep,
       bool last) {
    if (poisoned_) {
      throw std::runtime_error(
          "QShell request assembler is poisoned; reconnect required");
    }
    ++beats_;
    if (beats_ > max_packet_beats) {
      poison("QShell request exceeded the 64-beat provider bound");
    }
    if (discarding_) {
      if (last) {
        const auto message = discard_error_;
        reset_record();
        throw std::runtime_error(message);
      }
      if (beats_ == max_packet_beats) {
        poison("malformed QShell request has no bounded tlast");
      }
      return std::nullopt;
    }

    std::size_t bytes = 0;
    try {
      bytes = valid_bytes(keep);
      if (!shape_valid_) {
        shape_ = shape_from_header(data.data(), bytes);
        shape_valid_ = true;
      }
    } catch (const std::runtime_error &error) {
      return reject(error.what(), last);
    }

    if (beats_ > shape_.beats) {
      return reject("QShell request exceeds its declared length", last);
    }
    const bool final = beats_ == shape_.beats;
    const auto expected_bytes = final ? shape_.final_bytes : beat_bytes;
    if (bytes != expected_bytes) {
      return reject("QShell request beat boundary mismatch", last);
    }
    if (last != final) {
      if (final) {
        poison("QShell request omitted its declared tlast");
      }
      return reject("QShell request beat boundary mismatch", last);
    }

    record_.insert(record_.end(), data.begin(), data.begin() + bytes);
    if (!final) {
      return std::nullopt;
    }
    if (record_.size() != shape_.bytes) {
      poison("QShell request ended before its declared length");
    }
    auto result = record_;
    reset_record();
    return result;
  }

  bool poisoned() const { return poisoned_; }
  bool empty() const { return record_.empty() && !shape_valid_ && beats_ == 0; }

private:
  packet_shape shape_{};
  std::size_t beats_ = 0;
  std::vector<std::uint8_t> record_;
  bool shape_valid_ = false;
  bool discarding_ = false;
  bool poisoned_ = false;
  std::string discard_error_;

  void reset_record() {
    shape_ = {};
    beats_ = 0;
    record_.clear();
    shape_valid_ = false;
    discarding_ = false;
    discard_error_.clear();
  }

  [[noreturn]] void poison(const std::string &message) {
    reset_record();
    poisoned_ = true;
    throw std::runtime_error(message + "; reconnect required");
  }

  std::optional<std::vector<std::uint8_t>> reject(const std::string &message,
                                                   bool last) {
    shape_ = {};
    shape_valid_ = false;
    record_.clear();
    if (last) {
      reset_record();
      throw std::runtime_error(message);
    }
    if (beats_ >= max_packet_beats) {
      poison("malformed QShell request exceeded bounded discard");
    }
    discarding_ = true;
    discard_error_ = message;
    return std::nullopt;
  }
};

class bridge {
public:
  bridge(std::int32_t vfpga_id, std::chrono::milliseconds timeout,
         std::size_t expected_response_bytes)
      : thread_(vfpga_id, getpid()), timeout_(timeout),
        normal_response_shape_(shape_for_bytes(expected_response_bytes)),
        memory_(nullptr), rx_shape_{}, rx_beat_(0), rx_cached_(false),
        poisoned_(false) {
    memory_ = reinterpret_cast<std::uint8_t *>(thread_.getMem(
        {coyote::CoyoteAllocType::HPF, 2 * packet_storage_bytes}));
    if (memory_ == nullptr) {
      throw std::runtime_error("failed to allocate Coyote huge-page buffer");
    }
    std::memset(memory_, 0, 2 * packet_storage_bytes);
  }

  void write_beat(const std::array<std::uint8_t, beat_bytes> &data,
                  std::uint64_t keep, bool last) {
    ensure_healthy();
    std::optional<std::vector<std::uint8_t>> record;
    try {
      record = tx_.push(data, keep, last);
      if (record) {
        send_record(*record);
      }
    } catch (...) {
      if (tx_.poisoned() || record) {
        poisoned_ = true;
      }
      throw;
    }
  }

  std::array<std::uint8_t, beat_bytes> read_beat(std::uint64_t &keep,
                                                 bool &last) {
    ensure_healthy();
    if (!rx_cached_) {
      try {
        receive_record();
      } catch (...) {
        poisoned_ = true;
        throw;
      }
    }
    if (rx_beat_ >= rx_shape_.beats) {
      poisoned_ = true;
      throw std::runtime_error(
          "cached response beat index overflow; reconnect required");
    }

    // Logical sidebands are derived from the completed fixed descriptor; they
    // are not observations of the FPGA source tkeep/tlast signals.
    const auto valid =
        rx_beat_ + 1 == rx_shape_.beats ? rx_shape_.final_bytes : beat_bytes;
    std::array<std::uint8_t, beat_bytes> result{};
    std::memcpy(result.data(), rx_memory() + rx_beat_ * beat_bytes, valid);
    keep = low_keep(valid);
    last = rx_beat_ + 1 == rx_shape_.beats;
    ++rx_beat_;
    if (last) {
      rx_shape_ = {};
      rx_cached_ = false;
      rx_beat_ = 0;
    }
    return result;
  }

private:
  coyote::cThread thread_;
  std::chrono::milliseconds timeout_;
  packet_shape normal_response_shape_;
  std::uint8_t *memory_;
  packet_assembler tx_;
  packet_shape rx_shape_;
  std::size_t rx_beat_;
  bool rx_cached_;
  bool poisoned_;

  std::uint8_t *rx_memory() { return memory_ + packet_storage_bytes; }

  void ensure_healthy() const {
    if (poisoned_ || tx_.poisoned()) {
      throw std::runtime_error("QShell bridge link is poisoned; reconnect required");
    }
  }

  void send_record(const std::vector<std::uint8_t> &record) {
    const auto shape = shape_for_bytes(record.size());
    std::memset(memory_, 0, packet_storage_bytes);
    std::memcpy(memory_, record.data(), record.size());
    thread_.clearCompleted();
    for (std::size_t beat = 0; beat < shape.beats; ++beat) {
      const auto length =
          beat + 1 == shape.beats ? shape.final_bytes : beat_bytes;
      coyote::localSg sg = {
          .addr = memory_ + beat * beat_bytes,
          .len = static_cast<std::uint32_t>(length),
          .stream = 1,
      };
      thread_.invoke(coyote::CoyoteOper::LOCAL_READ, sg,
                     beat + 1 == shape.beats);
    }
    wait_for(coyote::CoyoteOper::LOCAL_READ);
  }

  void receive_record() {
    std::memset(rx_memory(), 0, packet_storage_bytes);
    thread_.clearCompleted();
    rx_shape_ = receive_fixed_response(
        rx_memory(), normal_response_shape_,
        [this](std::uint8_t *address, std::size_t bytes) {
          coyote::localSg sg = {
              .addr = address,
              .len = static_cast<std::uint32_t>(bytes),
              .stream = 1,
          };
          // LOCAL_WRITE copies one trusted, graph-sized correction record from
          // FPGA to host. Coyote reports only final descriptor completion.
          thread_.invoke(coyote::CoyoteOper::LOCAL_WRITE, sg, true);
        },
        [this]() { wait_for(coyote::CoyoteOper::LOCAL_WRITE); });

    // The driver exposes neither source tkeep/tlast nor a completed byte count.
    // Reconstruct beat metadata only from the fixed descriptor after QShell's
    // store-and-forward validation and frame commit have released the record.
    rx_cached_ = true;
    rx_beat_ = 0;
  }

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
  if (valid_bytes(low_keep(48)) != 48 ||
      valid_bytes(~std::uint64_t{0}) != beat_bytes) {
    return 1;
  }
  try {
    (void)valid_bytes(0x5);
    return 1;
  } catch (const std::runtime_error &) {
  }

  const auto make_first = [](std::uint32_t payload_bytes,
                             ::qshell::abi::record_class record_class,
                             std::uint32_t schema_id) {
    std::array<std::uint8_t, beat_bytes> first{};
    store_u32(first.data() + ::qshell::abi::offset::magic,
              ::qshell::abi::magic);
    first[::qshell::abi::offset::abi_version] = ::qshell::abi::version;
    first[::qshell::abi::offset::record_class] =
        static_cast<std::uint8_t>(record_class);
    store_u16(first.data() + ::qshell::abi::offset::header_bytes,
              header_bytes);
    store_u32(first.data() + ::qshell::abi::offset::payload_bytes,
              payload_bytes);
    store_u32(first.data() + ::qshell::abi::offset::schema_id, schema_id);
    return first;
  };

  const auto d3_request = shape_for_bytes(112);
  const auto d3_response = shape_for_bytes(170);
  const auto d9_request = shape_for_bytes(808);
  const auto d9_response = shape_for_bytes(3566);
  if (d3_request.beats != 2 || d3_request.final_bytes != 48 ||
      d3_response.beats != 3 || d3_response.final_bytes != 42 ||
      d9_request.beats != 13 || d9_request.final_bytes != 40 ||
      d9_response.beats != 56 || d9_response.final_bytes != 46) {
    return 1;
  }

  auto first = make_first(760, ::qshell::abi::record_class::syndrome, 0);
  if (shape_from_header(first.data(), beat_bytes).beats != 13) {
    return 1;
  }
  const auto d3_first = make_first(
      122, ::qshell::abi::record_class::correction,
      ::qshell::abi::schema_microblossom_decode_result);
  const auto d9_first = make_first(
      3518, ::qshell::abi::record_class::correction,
      ::qshell::abi::schema_microblossom_decode_result);
  if (!same_shape(accepted_response_shape(d3_first.data(), d3_response),
                  d3_response) ||
      !same_shape(accepted_response_shape(d9_first.data(), d9_response),
                  d9_response)) {
    return 1;
  }
  const auto error_first = make_first(
      24, ::qshell::abi::record_class::error, ::qshell::abi::schema_error);
  try {
    (void)accepted_response_shape(error_first.data(), d3_response);
    return 1;
  } catch (const std::runtime_error &) {
  }

  std::array<std::uint8_t, packet_storage_bytes> staged{};
  std::size_t submitted_descriptors = 0;
  std::size_t submitted_bytes = 0;
  bool completion_observed = false;
  const auto completed_shape = receive_fixed_response(
      staged.data(), d3_response,
      [&](std::uint8_t *address, std::size_t bytes) {
        if (address != staged.data() || completion_observed) {
          throw std::runtime_error("invalid fixed response submission order");
        }
        ++submitted_descriptors;
        submitted_bytes = bytes;
      },
      [&]() {
        completion_observed = true;
        std::memcpy(staged.data(), d3_first.data(), beat_bytes);
      });
  if (submitted_descriptors != 1 || submitted_bytes != d3_response.bytes ||
      !completion_observed || !same_shape(completed_shape, d3_response)) {
    return 1;
  }

  submitted_descriptors = 0;
  submitted_bytes = 0;
  completion_observed = false;
  bool response_published = false;
  try {
    const auto ignored_shape = receive_fixed_response(
        staged.data(), d3_response,
        [&](std::uint8_t *address, std::size_t bytes) {
          if (address != staged.data()) {
            throw std::runtime_error("invalid fixed response address");
          }
          ++submitted_descriptors;
          submitted_bytes = bytes;
        },
        [&]() {
          completion_observed = true;
          throw std::runtime_error("injected descriptor completion failure");
        });
    (void)ignored_shape;
    response_published = true;
  } catch (const std::runtime_error &) {
  }
  if (submitted_descriptors != 1 || submitted_bytes != d3_response.bytes ||
      !completion_observed || response_published) {
    return 1;
  }

  staged.fill(0);
  submitted_descriptors = 0;
  submitted_bytes = 0;
  completion_observed = false;
  try {
    (void)receive_fixed_response(
        staged.data(), d3_response,
        [&](std::uint8_t *address, std::size_t bytes) {
          if (address != staged.data() || completion_observed) {
            throw std::runtime_error("invalid fixed response submission order");
          }
          ++submitted_descriptors;
          submitted_bytes = bytes;
        },
        [&]() {
          completion_observed = true;
          std::memcpy(staged.data(), error_first.data(), beat_bytes);
          std::memcpy(staged.data() + 72, d3_first.data(), beat_bytes);
        });
    return 1;
  } catch (const std::runtime_error &) {
  }
  if (submitted_descriptors != 1 || submitted_bytes != d3_response.bytes ||
      !completion_observed) {
    return 1;
  }

  packet_assembler assembler;
  try {
    (void)assembler.push(first, ~std::uint64_t{0}, true);
    return 1;
  } catch (const std::runtime_error &) {
  }
  if (!assembler.empty()) {
    return 1;
  }
  first[::qshell::abi::offset::magic] ^= 1;
  if (assembler.push(first, ~std::uint64_t{0}, false).has_value()) {
    return 1;
  }
  try {
    std::array<std::uint8_t, beat_bytes> terminator{};
    (void)assembler.push(terminator, low_keep(48), true);
    return 1;
  } catch (const std::runtime_error &) {
  }
  first = make_first(64, ::qshell::abi::record_class::syndrome, 0);
  if (assembler.push(first, ~std::uint64_t{0}, false).has_value()) {
    return 1;
  }
  std::array<std::uint8_t, beat_bytes> final{};
  const auto recovered = assembler.push(final, low_keep(48), true);
  if (!recovered || recovered->size() != d3_request.bytes) {
    return 1;
  }

  packet_assembler unterminated;
  first[::qshell::abi::offset::magic] ^= 1;
  (void)unterminated.push(first, ~std::uint64_t{0}, false);
  try {
    for (std::size_t beat = 1; beat < max_packet_beats; ++beat) {
      (void)unterminated.push(final, ~std::uint64_t{0}, false);
    }
    return 1;
  } catch (const std::runtime_error &) {
  }
  if (!unterminated.poisoned()) {
    return 1;
  }

  try {
    (void)shape_for_bytes(packet_storage_bytes + 1);
    return 1;
  } catch (const std::runtime_error &) {
  }
  std::cout << "MICROBLOSSOM_QSHELL_COYOTE_BRIDGE_PASS"
               " request_beats=13 response_beats=56 storage_bytes=4096"
               " receive_descriptors=1 completion_before_publish=1"
               " first_beat_poll=0 shell_error_72=rejected\n";
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--self-test") {
    return self_test();
  }

  std::int32_t vfpga_id = 0;
  std::chrono::milliseconds timeout{1000};
  std::size_t response_bytes = default_response_bytes;
  bool response_bytes_set = false;
  bool continuation_bytes_set = false;
  for (int index = 1; index < argc; ++index) {
    const std::string argument(argv[index]);
    if (argument == "--vfpga" && index + 1 < argc) {
      vfpga_id = std::stoi(argv[++index]);
    } else if (argument == "--timeout-ms" && index + 1 < argc) {
      timeout = std::chrono::milliseconds(std::stoul(argv[++index]));
    } else if (argument == "--response-bytes" && index + 1 < argc) {
      response_bytes = std::stoul(argv[++index]);
      response_bytes_set = true;
    } else if (argument == "--continuation-bytes" && index + 1 < argc) {
      const auto continuation = std::stoul(argv[++index]);
      if (continuation == 0 || continuation > beat_bytes) {
        std::cerr << "continuation must contain 1..64 bytes\n";
        return 2;
      }
      response_bytes = beat_bytes + continuation;
      continuation_bytes_set = true;
    } else {
      std::cerr << "usage: " << argv[0]
                << " [--vfpga ID] [--timeout-ms MS]"
                   " [--response-bytes BYTES | --continuation-bytes BYTES]"
                   " [--self-test]\n";
      return 2;
    }
  }
  if (response_bytes_set && continuation_bytes_set) {
    std::cerr << "--response-bytes and --continuation-bytes are mutually exclusive\n";
    return 2;
  }
  if (response_bytes <= beat_bytes || response_bytes > packet_storage_bytes) {
    std::cerr << "response packet must contain 65..4096 bytes\n";
    return 2;
  }

  try {
    bridge link(vfpga_id, timeout, response_bytes);
    while (true) {
      const auto request = std::cin.get();
      if (request == std::char_traits<char>::eof()) {
        return 0;
      }
      try {
        if (request == request_write) {
          const auto last_value = std::cin.get();
          if (last_value == std::char_traits<char>::eof()) {
            throw std::runtime_error("truncated write request");
          }
          const bool last = last_value != 0;
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
