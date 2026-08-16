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

namespace {

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
  bssl::UniquePtr<SSL_CTX> destination(SSL_CTX_new(TLS_with_buffers_method()));
  if (!source || !destination) {
    std::fputs("could not create BoringSSL contexts\n", stderr);
    return 1;
  }
  SSL_CTX_set_custom_verify(source.get(), SSL_VERIFY_PEER, verify_ok);
  SSL_CTX_set_custom_verify(destination.get(), SSL_VERIFY_PEER, verify_ok);
  auto* const source_impl = bssl::FromOpaque(source.get());
  auto* const destination_impl = bssl::FromOpaque(destination.get());
  if (torrent7_invoke_boringssl_custom_verify(source_impl) != ssl_verify_ok
      || torrent7_load_boringssl_protocol_method(source_impl) == nullptr) {
    std::fputs("normal BoringSSL authenticated pointer use failed\n", stderr);
    return 1;
  }

  using torrent7::test_support::replay_triggers_pointer_authentication_failure;
  if (!replay_triggers_pointer_authentication_failure([&] {
        replay_context_bytes(destination_impl, source_impl);
        static_cast<void>(torrent7_invoke_boringssl_custom_verify(destination_impl));
      })) {
    std::fputs("BoringSSL custom-verify callback replay was accepted\n", stderr);
    return 1;
  }
  if (!replay_triggers_pointer_authentication_failure([&] {
        replay_context_bytes(destination_impl, source_impl);
        if (torrent7_load_boringssl_protocol_method(destination_impl) == nullptr) {
          ::_exit(90);
        }
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

  if (!verify_allocation_semantics()) {
    std::fputs("BoringSSL allocation semantics failed\n", stderr);
    return 1;
  }
  if (!verify_digest_move()) {
    std::fputs("BoringSSL digest move failed\n", stderr);
    return 1;
  }
  return 0;
}
