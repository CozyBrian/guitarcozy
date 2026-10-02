#include "core/engine.h"
#include "test.h"

using namespace gc;

TEST(star_rating_balances_accuracy_and_multiplier) {
  // accuracy alone carries you to three stars, never past
  CHECK(starRating(150, 100, false, 0.85) == 3);
  CHECK(starRating(150, 100, false, 1.0) == 3);
  CHECK(starRating(150, 100, false, 0.70) == 2);
  CHECK(starRating(150, 100, false, 0.60) == 1);
  // four and five need the multiplier: 95% with 3.0x, 98% with 4.0x
  CHECK(starRating(300, 100, false, 0.95) == 4);
  CHECK(starRating(300, 100, false, 0.90) == 3);
  CHECK(starRating(400, 100, false, 0.98) == 5);
  CHECK(starRating(400, 100, false, 0.94) == 4);
  // the pure GH3 ladder still applies on its own
  CHECK(starRating(360, 100, false, 0.80) == 4);
  CHECK(starRating(440, 100, false, 0.80) == 5);
  // full combo is always gold
  CHECK(starRating(50, 100, true, 1.0) == 6);
}
