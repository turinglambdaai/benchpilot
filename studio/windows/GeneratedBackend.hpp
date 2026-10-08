// Generated from the default Rivet scaffold backend.
// raco rivet build replaces this file from the application's actual schema.
// This checked-in copy matches the scaffold backend's schema (greet/notify
// RPCs plus the counter State accessors the host renders) so the host
// compiles before the first build, mirroring the Linux scaffold header.
#pragma once

#include <cstdint>
#include <exception>
#include <functional>
#include <future>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>

#include "backend.hpp"

namespace rivet_app {

inline constexpr char kModuleName[] = "backend";
inline constexpr char kEntryName[] = "start";
inline constexpr char kDisplayName[] = "Rivet";
inline constexpr char kVersion[] = "0.1.0";
inline constexpr std::int64_t kBuild = 1;
inline constexpr char kIdentifier[] = "dev.rivet.app";
inline constexpr char kReleaseChannel[] = "stable";

template <typename T>
struct Result {
  std::optional<T> value;
  std::exception_ptr error;

  bool succeeded() const noexcept { return value.has_value() && !error; }
  T const& get() const {
    if (error) std::rethrow_exception(error);
    if (!value) throw std::runtime_error("Rivet async result has no value");
    return *value;
  }
};

class API {
 public:
  explicit API(rivet::windows::Backend& backend) : backend_(backend) {}

  std::future<std::string> greet(std::string name) {
    auto raw = backend_.call("greet", rivet::Value::List{rivet::Value(std::move(name))});
    return std::async(std::launch::deferred,
                      [raw = std::move(raw)]() mutable -> std::string {
                        auto value = raw.get();
                        if (auto text = std::get_if<std::string>(&value.data)) {
                          return *text;
                        }
                        throw std::runtime_error("Rivet result type mismatch: String");
                      });
  }

  std::future<std::int64_t> increment(std::int64_t value) {
    auto raw = backend_.call("increment", rivet::Value::List{rivet::Value(value)});
    return std::async(std::launch::deferred,
                      [raw = std::move(raw)]() mutable -> std::int64_t {
                        auto result = raw.get();
                        if (auto number = std::get_if<std::int64_t>(&result.data)) {
                          return *number;
                        }
                        throw std::runtime_error("Rivet result type mismatch: Int64");
                      });
  }

  // State accessors: completion callbacks run on the backend reader thread
  // and must dispatch to the UI thread before touching widgets.
  void get_counter_async(
      std::function<void(rivet_app::Result<std::int64_t>)> completion) {
    (void)backend_.get_state_async(
        "counter",
        [completion = std::move(completion)](rivet::windows::CallResult call) mutable {
          completion(unbox_int64(std::move(call)));
        });
  }

  void set_counter_async(
      std::int64_t next,
      std::function<void(rivet_app::Result<std::int64_t>)> completion) {
    (void)backend_.set_state_async(
        "counter", rivet::Value(next),
        [completion = std::move(completion)](rivet::windows::CallResult call) mutable {
          completion(unbox_int64(std::move(call)));
        });
  }

 private:
  static rivet_app::Result<std::int64_t> unbox_int64(rivet::windows::CallResult call) {
    rivet_app::Result<std::int64_t> result;
    if (!call.succeeded()) {
      result.error = call.error ? call.error :
          std::make_exception_ptr(std::runtime_error("unknown backend failure"));
      return result;
    }
    if (auto number = std::get_if<std::int64_t>(&call.value->data)) {
      result.value = *number;
      return result;
    }
    result.error = std::make_exception_ptr(
        std::runtime_error("Rivet result type mismatch: Int64"));
    return result;
  }

  rivet::windows::Backend& backend_;
};

}  // namespace rivet_app
