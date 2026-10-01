#include <fstream>
#include <iterator>
#include "core/chart_parser.h"
#include "core/chart_scan.h"
#include "test.h"

using namespace gc;

TEST(quick_scan_matches_full_parse) {
  std::ifstream in(std::string(GC_ASSETS_DIR) + "/demo/notes.chart", std::ios::binary);
  const std::string text((std::istreambuf_iterator<char>(in)), {});
  CHECK(!text.empty());
  const Chart full = parseChart(text);
  const ChartScan quick = scanChartQuick(text);
  CHECK(quick.meta.name == full.meta.name);
  CHECK(quick.tracks.size() == full.tracks.size());
  for (const auto& t : quick.tracks) {
    const Track* ft = full.track(t.instrument, t.difficulty);
    CHECK(ft != nullptr);
    if (ft) CHECK(int(ft->notes.size()) == t.noteCount);
  }
  CHECK(std::abs(quick.lengthSeconds - full.chartLength) < 0.05);
}
