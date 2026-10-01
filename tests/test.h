// Minimal test harness: CHECK/CHECK_NEAR macros, one TEST per function, registered at static init.
#pragma once
#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

struct TestCase { const char* name; std::function<void()> fn; };
std::vector<TestCase>& allTests();
int& failCount();
struct TestRegistrar { TestRegistrar(const char* name, std::function<void()> fn) { allTests().push_back({name, std::move(fn)}); } };

#define TEST(name) static void test_##name(); static TestRegistrar reg_##name(#name, test_##name); static void test_##name()
#define CHECK(cond) do { if (!(cond)) { std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failCount()++; } } while (0)
#define CHECK_EQ(a, b) do { auto _a = (a); auto _b = (b); if (!(_a == _b)) { std::printf("  FAIL %s:%d: %s == %s  (got %s vs %s)\n", __FILE__, __LINE__, #a, #b, std::to_string(_a).c_str(), std::to_string(_b).c_str()); failCount()++; } } while (0)
#define CHECK_NEAR(a, b, eps) do { double _a = (a), _b = (b); if (std::fabs(_a - _b) > (eps)) { std::printf("  FAIL %s:%d: %s ~= %s  (got %g vs %g)\n", __FILE__, __LINE__, #a, #b, _a, _b); failCount()++; } } while (0)
