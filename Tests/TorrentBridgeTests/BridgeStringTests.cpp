#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <array>
#include <cstdint>
#include <span>
#include <string>

namespace {

[[nodiscard]] std::string replacement_character()
{
    std::string value;
    value.reserve(kUTF8ReplacementCharacter.size());
    for (unsigned char const byte : kUTF8ReplacementCharacter) {
        value.push_back(static_cast<char>(byte));
    }
    return value;
}

} // namespace

TEST_CASE("C string views and C buffers tolerate null inputs")
{
    CHECK(c_string_view(nullptr).empty());

    CHECK(output_buffer(nullptr, 8).empty());
    std::array<char, 8> output{};
    CHECK(output_buffer(output.data(), -1).empty());
    CHECK(output_buffer(output.data(), 0).empty());
    CHECK(output_buffer(output.data(), static_cast<int32_t>(output.size())).size() == output.size());
}

TEST_CASE("copy_string_dynamic always writes a terminated C string")
{
    std::array<char, 6> output{};
    copy_string_dynamic(std::span{output}, "abcdef");

    CHECK(bridge_tests::string_from_c_buffer(std::span{output}) == "abcde");
    CHECK(output.back() == '\0');
}

TEST_CASE("copy_string_dynamic replaces control bytes and invalid UTF-8")
{
    std::string source("ok");
    source.push_back('\x01');
    source.push_back('x');
    source.push_back(static_cast<char>(0xc0));
    source.push_back('y');

    std::array<char, 32> output{};
    copy_string_dynamic(std::span{output}, source);

    CHECK(bridge_tests::string_from_c_buffer(std::span{output}) == "ok" + replacement_character() + "x" + replacement_character() + "y");
}

TEST_CASE("copy_string_dynamic does not split a multi-byte UTF-8 sequence")
{
    std::array<char, 3> too_small{};
    copy_string_dynamic(std::span{too_small}, "\xe2\x82\xac");
    CHECK(bridge_tests::string_from_c_buffer(std::span{too_small}).empty());

    std::array<char, 5> exact{};
    copy_string_dynamic(std::span{exact}, "\xe2\x82\xac!");
    CHECK(bridge_tests::string_from_c_buffer(std::span{exact}) == "\xe2\x82\xac!");
}

TEST_CASE("utf8_sequence accepts canonical UTF-8 and rejects malformed sequences")
{
    std::string const ascii("a");
    CHECK(utf8_sequence(ascii, 0).length == 1U);
    CHECK(utf8_sequence(ascii, 0).valid);

    std::string const four_byte("\xf0\x9f\x8c\x80");
    CHECK(utf8_sequence(four_byte, 0).length == 4U);
    CHECK(utf8_sequence(four_byte, 0).valid);

    std::string const overlong_two_byte("\xc0\x80");
    CHECK(utf8_sequence(overlong_two_byte, 0).length == 1U);
    CHECK_FALSE(utf8_sequence(overlong_two_byte, 0).valid);

    std::string const surrogate("\xed\xa0\x80");
    CHECK(utf8_sequence(surrogate, 0).length == 1U);
    CHECK_FALSE(utf8_sequence(surrogate, 0).valid);

    std::string const past_unicode("\xf4\x90\x80\x80");
    CHECK(utf8_sequence(past_unicode, 0).length == 1U);
    CHECK_FALSE(utf8_sequence(past_unicode, 0).valid);
}

TEST_CASE("run_bridge_operation copies bridge and exception errors")
{
    std::array<char, 128> output{};
    int32_t const bridge_result = run_bridge_operation(std::span{output}, 9, [] {
        return bridge_error(7, "Bridge failure.");
    });
    CHECK(bridge_result == 7);
    CHECK(bridge_tests::string_from_c_buffer(std::span{output}) == "Bridge failure.");

    int32_t const exception_result = run_bridge_operation(std::span{output}, 9, []() -> BridgeResult {
        throw std::runtime_error("Thrown failure.");
    });
    CHECK(exception_result == 9);
    CHECK(bridge_tests::string_from_c_buffer(std::span{output}) == "Thrown failure.");
}
