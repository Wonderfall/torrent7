#include "crypto/fipsmodule/rand/internal.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <openssl/aead.h>
#include <openssl/ctrdrbg.h>
#include <openssl/err.h>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace
{
using Bytes = std::vector<std::uint8_t>;

[[nodiscard]] Bytes decode(std::string_view hex)
{
  if (hex == "\"\"")
    return {}; // Upstream also spells an empty byte string this way.
  auto nibble = [](char c) -> std::uint8_t
  {
    if (c >= '0' && c <= '9')
      return static_cast<std::uint8_t>(c - '0');
    if (c >= 'a' && c <= 'f')
      return static_cast<std::uint8_t>(c - 'a' + 10);
    if (c >= 'A' && c <= 'F')
      return static_cast<std::uint8_t>(c - 'A' + 10);
    throw std::runtime_error("invalid fixture hex");
  };
  if (hex.size() % 2)
    throw std::runtime_error("odd fixture hex length");
  Bytes result;
  result.reserve(hex.size() / 2);
  for (std::size_t i = 0; i < hex.size(); i += 2)
    result.push_back(static_cast<std::uint8_t>((nibble(hex.at(i)) << 4) | nibble(hex.at(i + 1))));
  return result;
}

// Read the vectors from the verified, pinned BoringSSL checkout, so the tests
// exercise independent expected outputs without maintaining copied fixtures.
using Record = std::map<std::string, Bytes, std::less<>>;

[[nodiscard]] std::string_view trim(std::string_view value)
{
  auto const first = value.find_first_not_of(" \t\r");
  if (first == std::string_view::npos)
    return {};
  return value.substr(first, value.find_last_not_of(" \t\r") - first + 1);
}

[[nodiscard]] std::vector<Record> read_vectors(std::filesystem::path const &path)
{
  if (std::filesystem::file_size(path) > 1024 * 1024)
    throw std::runtime_error("oversized vector fixture");
  std::ifstream stream(path);
  if (!stream)
    throw std::runtime_error("cannot open vector fixture");
  std::vector<Record> records;
  Record record;
  auto finish = [&]
  {
    if (!record.empty())
    {
      records.push_back(std::move(record));
      record.clear();
    }
  };
  for (std::string line; std::getline(stream, line);)
  {
    auto const value = trim(line);
    if (value.empty())
    {
      finish();
      continue;
    }
    if (value.front() == '#')
      continue;
    auto const separator = value.find_first_of(":=");
    if (separator == std::string_view::npos ||
        !record.emplace(trim(value.substr(0, separator)), decode(trim(value.substr(separator + 1))))
             .second)
      throw std::runtime_error("invalid or duplicate vector field");
  }
  if (!stream.eof())
    throw std::runtime_error("cannot read vector fixture");
  finish();
  return records;
}

[[nodiscard]] bool check_gcm(Record const &test, int bits)
{
  auto const &key = test.at("KEY");
  auto const &nonce = test.at("NONCE");
  auto const &input = test.at("IN");
  auto const &aad = test.at("AD");
  auto const &tag = test.at("TAG");
  if (test.size() != 6 || tag.empty())
    return false;
  auto expected = test.at("CT");
  expected.insert(expected.end(), tag.begin(), tag.end());
  bssl::UniquePtr<EVP_AEAD_CTX> ctx(
      EVP_AEAD_CTX_new(bits == 128 ? EVP_aead_aes_128_gcm() : EVP_aead_aes_256_gcm(), key.data(),
                       key.size(), tag.size()));
  if (!ctx)
    return false;
  Bytes encrypted(input.size() + EVP_AEAD_MAX_OVERHEAD);
  std::size_t length = 0;
  if (!EVP_AEAD_CTX_seal(ctx.get(), encrypted.data(), &length, encrypted.size(), nonce.data(),
                         nonce.size(), input.data(), input.size(), aad.data(), aad.size()))
    return false;
  encrypted.resize(length);
  if (encrypted != expected)
    return false;
  Bytes plaintext(encrypted.size());
  if (!EVP_AEAD_CTX_open(ctx.get(), plaintext.data(), &length, plaintext.size(), nonce.data(),
                         nonce.size(), encrypted.data(), encrypted.size(), aad.data(), aad.size()))
    return false;
  plaintext.resize(length);
  if (plaintext != input)
    return false;
  encrypted.back() ^= 1;
  plaintext.resize(encrypted.size());
  return !EVP_AEAD_CTX_open(ctx.get(), plaintext.data(), &length, plaintext.size(), nonce.data(),
                            nonce.size(), encrypted.data(), encrypted.size(), aad.data(),
                            aad.size());
}

[[nodiscard]] bool check_drbg(Record const &test, bool df)
{
  auto const &entropy = test.at("EntropyInput");
  auto const nonce = df ? std::span(test.at("Nonce")) : std::span<std::uint8_t const>{};
  auto const &personalization = test.at("PersonalizationString");
  auto const &reseed = test.at("EntropyInputReseed");
  auto const &reseed_additional = test.at("AdditionalInputReseed");
  auto const &additional1 = test.at("AdditionalInput1");
  auto const &additional2 = test.at("AdditionalInput2");
  auto const &expected = test.at("ReturnedBits");
  // The internal API borrows exactly 16 nonce bytes when derivation is enabled.
  if (test.size() != (df ? 8 : 7) || (df && nonce.size() != 16) || expected.empty())
    return false;
  struct State
  {
    CTR_DRBG_STATE value{};
    ~State() { CTR_DRBG_clear(&value); }
  } state;
  if (!bssl::CTR_DRBG_init(&state.value, df, entropy.data(), entropy.size(),
                           df ? nonce.data() : nullptr, personalization.data(),
                           personalization.size()))
    return false;
  if (!CTR_DRBG_reseed_ex(&state.value, reseed.data(), reseed.size(), reseed_additional.data(),
                          reseed_additional.size()))
    return false;
  Bytes output(expected.size());
  if (!CTR_DRBG_generate(&state.value, output.data(), output.size(), additional1.data(),
                         additional1.size()))
    return false;
  if (!CTR_DRBG_generate(&state.value, output.data(), output.size(), additional2.data(),
                         additional2.size()))
    return false;
  return output == expected;
}
} // namespace

int main(int argc, char **argv)
{
  try
  {
    if (argc != 2)
      throw std::runtime_error("expected the pinned BoringSSL source directory");
    // SAFETY: the system entry point supplies argc initialized argv entries,
    // which remain alive for this invocation.
    std::span<char *const> const arguments(argv, static_cast<std::size_t>(argc));
    std::filesystem::path const source(arguments[1]);
    std::size_t gcm_count = 0, drbg_count = 0;
    for (int const bits : {128, 256})
    {
      auto const name = "aes_" + std::to_string(bits) + "_gcm_tests.txt";
      auto const cases = read_vectors(source / "crypto/cipher/test" / name);
      if (cases.size() != (bits == 128 ? 74 : 66))
        throw std::runtime_error("AES-GCM fixture count changed");
      for (auto const &test : cases)
      {
        if (!check_gcm(test, bits))
          throw std::runtime_error("AES-GCM vector " + std::to_string(gcm_count) + " failed");
        ERR_clear_error(); // Changed-tag rejection deliberately sets the error queue.
        ++gcm_count;
      }
    }
    for (bool const df : {false, true})
    {
      auto const name = df ? "ctrdrbg_df_vectors.txt" : "ctrdrbg_vectors.txt";
      auto const cases = read_vectors(source / "crypto/fipsmodule/rand" / name);
      if (cases.size() != (df ? 60 : 240))
        throw std::runtime_error("CTR-DRBG fixture count changed");
      for (auto const &test : cases)
      {
        if (!check_drbg(test, df))
          throw std::runtime_error("CTR-DRBG vector " + std::to_string(drbg_count) + " failed");
        ++drbg_count;
      }
    }
    std::printf("Passed %zu upstream AES-GCM vectors (seal, open, changed-tag rejection).\n",
                gcm_count);
    std::printf("Passed %zu upstream CTR-DRBG vectors (reseed, with/without derivation).\n",
                drbg_count);
    return 0;
  }
  catch (std::exception const &error)
  {
    std::fprintf(stderr, "BoringSSL crypto vectors: %s\n", error.what());
    return 1;
  }
}
