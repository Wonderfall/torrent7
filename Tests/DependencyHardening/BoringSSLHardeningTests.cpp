#include "PointerAuthenticationFailureTestSupport.hpp"

#include <openssl/digest.h>
#include <openssl/err.h>
#include <openssl/mem.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>

#include <ssl/internal.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <algorithm>
#include <span>
#include <vector>

namespace {

const void* volatile observed_protocol_method = nullptr;

struct ReplaySSLContexts {
  std::vector<bssl::UniquePtr<SSL_CTX>> decoys;
  bssl::UniquePtr<SSL_CTX> source;
  bssl::UniquePtr<SSL_CTX> destination;
};

[[nodiscard]] ReplaySSLContexts make_replay_ssl_contexts(std::size_t attempt)
{
  ReplaySSLContexts result;
  result.decoys.reserve(attempt);
  for (std::size_t index = 0; index < attempt; ++index) {
    result.decoys.emplace_back(SSL_CTX_new(TLS_with_buffers_method()));
    if (!result.decoys.back()) {
      torrent7::test_support::fail_replay_attempt_setup();
    }
  }
  result.source.reset(SSL_CTX_new(TLS_with_buffers_method()));
  result.destination.reset(SSL_CTX_new(TLS_with_buffers_method()));
  if (!result.source || !result.destination) {
    torrent7::test_support::fail_replay_attempt_setup();
  }
  return result;
}

struct TypedAllocationA {
  std::array<std::uint8_t, 17> bytes{};
};

struct TypedAllocationB {
  std::array<std::uint64_t, 5> words{};
};

ssl_verify_result_t verify_ok(SSL*, std::uint8_t*) { return ssl_verify_ok; }

__attribute__((noinline)) void replay_context_bytes(
    bssl::SSLContext* destination, bssl::SSLContext const* source)
{
  std::memcpy(static_cast<void*>(destination),
              static_cast<void const*>(source),
              sizeof(*destination));
}

[[nodiscard]] bool is_aligned(void const* pointer)
{
  return reinterpret_cast<std::uintptr_t>(pointer) % alignof(std::max_align_t) == 0;
}

[[nodiscard]] bool verify_allocation_semantics()
{
  constexpr std::size_t initial_size = 64;
  constexpr std::size_t grown_size = 128;
  auto* memory = static_cast<std::uint8_t*>(OPENSSL_malloc(initial_size));
  if (memory == nullptr || !is_aligned(memory)) {
    OPENSSL_free(memory);
    return false;
  }
  std::memset(memory, 0xa5, initial_size);
  auto* grown = static_cast<std::uint8_t*>(OPENSSL_realloc(memory, grown_size));
  if (grown == nullptr) {
    OPENSSL_free(memory);
    return false;
  }
  memory = grown;
  if (!is_aligned(memory)) {
    OPENSSL_free(memory);
    return false;
  }
  for (std::size_t index = 0; index < initial_size; ++index) {
    if (memory[index] != 0xa5) {
      OPENSSL_free(memory);
      return false;
    }
  }
  OPENSSL_free(memory);

  auto* zeroed = static_cast<std::uint8_t*>(OPENSSL_zalloc(initial_size));
  if (zeroed == nullptr || !is_aligned(zeroed)) {
    OPENSSL_free(zeroed);
    return false;
  }
  for (std::size_t index = 0; index < initial_size; ++index) {
    if (zeroed[index] != 0) {
      OPENSSL_free(zeroed);
      return false;
    }
  }
  OPENSSL_free(zeroed);

  auto* array = static_cast<std::uint8_t*>(OPENSSL_calloc(4, 16));
  if (array == nullptr || !is_aligned(array)) {
    OPENSSL_free(array);
    return false;
  }
  for (std::size_t index = 0; index < initial_size; ++index) {
    if (array[index] != 0) {
      OPENSSL_free(array);
      return false;
    }
  }
  OPENSSL_free(array);

  ERR_clear_error();
  if (OPENSSL_calloc(std::numeric_limits<std::size_t>::max(), 2) != nullptr) {
    return false;
  }
  ERR_clear_error();
  return true;
}

[[nodiscard]] bool verify_resize_boundaries()
{
  constexpr std::size_t initial_size = 64;
  constexpr std::size_t shrunk_size = 17;
  std::unique_ptr<std::uint8_t, decltype(&OPENSSL_free)> memory(
      static_cast<std::uint8_t*>(OPENSSL_malloc(initial_size)), &OPENSSL_free);
  if (!memory) return false;
  std::span<std::uint8_t> const original(memory.get(), initial_size);
  std::ranges::fill(original, 0xa5);
  auto* const shrunk = static_cast<std::uint8_t*>(OPENSSL_realloc(memory.get(), shrunk_size));
  if (shrunk == nullptr) return false;
  // A successful realloc consumes the old allocation; transfer the new owner.
  static_cast<void>(memory.release());
  memory.reset(shrunk);
  std::span<std::uint8_t const> const bytes(memory.get(), shrunk_size);
  if (!is_aligned(memory.get()) || !std::ranges::all_of(bytes, [](auto byte) { return byte == 0xa5; }))
    return false;
  auto* const failed = OPENSSL_realloc(memory.get(), std::numeric_limits<std::size_t>::max());
  if (failed != nullptr) {
    static_cast<void>(memory.release());
    OPENSSL_free(failed);
    return false;
  }
  ERR_clear_error();
  // Failed growth must leave the original allocation owned, readable, and freeable.
  return std::ranges::all_of(bytes, [](auto byte) { return byte == 0xa5; });
}

[[nodiscard]] bool verify_digest_move()
{
  bssl::UniquePtr<EVP_MD_CTX> source(EVP_MD_CTX_new());
  bssl::UniquePtr<EVP_MD_CTX> destination(EVP_MD_CTX_new());
  if (!source || !destination) {
    return false;
  }

  constexpr std::array<std::uint8_t, 3> input{'a', 'b', 'c'};
  std::array<std::uint8_t, SHA256_DIGEST_LENGTH> actual{};
  std::array<std::uint8_t, SHA256_DIGEST_LENGTH> expected{};
  unsigned int actual_size = 0;
  if (EVP_DigestInit_ex(source.get(), EVP_sha256(), nullptr) != 1
      || EVP_DigestUpdate(source.get(), input.data(), input.size()) != 1) {
    return false;
  }
  EVP_MD_CTX_move(destination.get(), source.get());
  if (EVP_DigestFinal_ex(destination.get(), actual.data(), &actual_size) != 1
      || actual_size != actual.size()
      || SHA256(input.data(), input.size(), expected.data()) == nullptr) {
    return false;
  }
  return actual == expected;
}

} // namespace

extern "C" __attribute__((noinline)) ssl_verify_result_t
torrent7_invoke_boringssl_custom_verify(bssl::SSLContext* context)
{
  std::uint8_t alert = 0;
  return context->custom_verify_callback(nullptr, &alert);
}

extern "C" __attribute__((noinline)) bssl::SSL_PROTOCOL_METHOD const*
torrent7_load_boringssl_protocol_method(bssl::SSLContext* context)
{
  return context->method;
}

extern "C" __attribute__((noinline)) TypedAllocationA*
torrent7_new_boringssl_typed_a()
{
  return bssl::New<TypedAllocationA>();
}

extern "C" __attribute__((noinline)) TypedAllocationB*
torrent7_new_boringssl_typed_b()
{
  return bssl::New<TypedAllocationB>();
}

int main()
{
  bssl::UniquePtr<SSL_CTX> source(SSL_CTX_new(TLS_with_buffers_method()));
  if (!source) {
    std::fputs("could not create BoringSSL context\n", stderr);
    return 1;
  }
  SSL_CTX_set_custom_verify(source.get(), SSL_VERIFY_PEER, verify_ok);
  auto* const source_impl = bssl::FromOpaque(source.get());
  if (torrent7_invoke_boringssl_custom_verify(source_impl) != ssl_verify_ok
      || torrent7_load_boringssl_protocol_method(source_impl) == nullptr) {
    std::fputs("normal BoringSSL authenticated pointer use failed\n", stderr);
    return 1;
  }

  using torrent7::test_support::complete_replay_without_authentication_fault;
  using torrent7::test_support::replay_triggers_pointer_authentication_failure;
  if (!replay_triggers_pointer_authentication_failure([](std::size_t attempt) {
        auto replay = make_replay_ssl_contexts(attempt);
        SSL_CTX_set_custom_verify(replay.source.get(), SSL_VERIFY_PEER, verify_ok);
        SSL_CTX_set_custom_verify(
            replay.destination.get(), SSL_VERIFY_PEER, verify_ok);
        auto* const replay_source_impl = bssl::FromOpaque(replay.source.get());
        auto* const replay_destination_impl =
            bssl::FromOpaque(replay.destination.get());
        replay_context_bytes(replay_destination_impl, replay_source_impl);
        static_cast<void>(
            torrent7_invoke_boringssl_custom_verify(replay_destination_impl));
        complete_replay_without_authentication_fault();
      })) {
    std::fputs("BoringSSL custom-verify callback replay was accepted\n", stderr);
    return 1;
  }
  if (!replay_triggers_pointer_authentication_failure([](std::size_t attempt) {
        auto replay = make_replay_ssl_contexts(attempt);
        auto* const replay_source_impl = bssl::FromOpaque(replay.source.get());
        auto* const replay_destination_impl =
            bssl::FromOpaque(replay.destination.get());
        replay_context_bytes(replay_destination_impl, replay_source_impl);
        observed_protocol_method =
            torrent7_load_boringssl_protocol_method(replay_destination_impl);
        complete_replay_without_authentication_fault();
      })) {
    std::fputs("BoringSSL protocol-method pointer replay was accepted\n", stderr);
    return 1;
  }

  auto* typed_a = torrent7_new_boringssl_typed_a();
  auto* typed_b = torrent7_new_boringssl_typed_b();
  if (typed_a == nullptr || typed_b == nullptr) {
    bssl::Delete(typed_a);
    bssl::Delete(typed_b);
    std::fputs("typed BoringSSL allocation failed\n", stderr);
    return 1;
  }
  bssl::Delete(typed_a);
  bssl::Delete(typed_b);

  if (!verify_allocation_semantics() || !verify_resize_boundaries()) {
    std::fputs("BoringSSL allocation semantics failed\n", stderr);
    return 1;
  }
  if (!verify_digest_move()) {
    std::fputs("BoringSSL digest move failed\n", stderr);
    return 1;
  }
  return 0;
}
