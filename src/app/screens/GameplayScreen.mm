#import "GameplayScreen.h"
#import "Chrome.h"
#import "ResultsScreen.h"
#import "OptionsScreen.h"
#include <memory>
#include <thread>
#include <mutex>
#include <atomic>
#include "app/Library.h"
#include "app/Settings.h"
#include "audio/mixer.h"
#include "audio/sfx.h"
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#include <unistd.h>
#import <CoreVideo/CoreVideo.h>
#include "core/engine.h"
#include "platform/song_loader.h"
#include "platform/gamepad.h"
#include "render/renderer.h"

using namespace gc;

static NSString* fmtTime(double sec) { int s = int(std::max(0.0, sec) + 0.5); return [NSString stringWithFormat:@"%02d:%02d", s / 60, s % 60]; }
static NSString* fmtScore(int v) { NSNumberFormatter* f = [NSNumberFormatter new]; f.numberStyle = NSNumberFormatterDecimalStyle; return [f stringFromNumber:@(v)]; }

@interface GameplayScreen ()
@property(nonatomic, strong) id<MTLTexture> lastTexture;
@end

@implementation GameplayScreen {
  std::string _songId, _mode;
  Instrument _instrument;
  Difficulty _difficulty;
  std::unique_ptr<LoadedSong> _song;
  const Track* _track;
  std::unique_ptr<GameEngine> _engine;
  std::unique_ptr<render::Renderer> _renderer;
  std::unique_ptr<audio::Mixer> _mixer;
  int _playerStem;
  int _frets, _padFrets;
  bool _whammyKey, _pausedByThisKey;
  float _padWhammy;
  int _lyricIndex;
  int _lightIndex;
  std::vector<double> _missTimes;
  std::vector<float> _offsets;   // hit offsets in ms for the results histogram
  double _timingUntil;
  bool _spReadyChimed;
  float _crowdLevel;
  bool _tiltArmed;
  // replays: recorded input stream (type 0 frets, 1 strum, 2 star power, 3 whammy x1000)
  struct Rec { double t; int type; int value; };
  std::vector<Rec> _recording;
  std::vector<Rec> _replay;
  size_t _replayPos;
  bool _isReplay;
  int _lastWhammyRec;
  NSString* _replayPath;
  // engine thread: the engine advances at ~1 kHz independent of the display link; input arrives as timestamped commands
  struct InputCmd { double t; int type; int value; };  // 0 frets, 1 strum, 2 star power
  std::thread _engineThread;
  std::atomic<bool> _engineRun;
  std::mutex _engineMutex;      // guards every GameEngine call and the pending event list
  std::mutex _inputMutex;
  std::vector<InputCmd> _inputQueue;
  std::vector<EngineEvent> _pendingEvents;
  std::atomic<float> _whammyAtomic;
  EngineStats _stats;           // snapshot for the HUD, refreshed each frame under the lock
  // song video background
  AVPlayer* _video;
  AVPlayerItemVideoOutput* _videoOut;
  CVMetalTextureCacheRef _videoCache;
  id<MTLTexture> _videoTex;
  std::atomic<bool> _paused, _finished, _resuming;
  bool _bot, _countdownDone, _practice, _loop;
  double _practiceStart, _practiceEnd, _speed, _startTime, _botStrumAt, _lastFrame, _pausedAtHost, _finishAt, _countdownTarget;
  GCStage* _stage;
  // HUD
  GCLabel *_score, *_streak, *_streakMsg, *_mult, *_multLbl, *_rockState, *_time, *_countdown, *_banner, *_solo, *_lyrics, *_timing, *_timingMs;
  GCElement* _timingBox;
  GCBox *_timingZone, *_timingMarker;
  GCBox *_spBar, *_rockFill, *_progress;
  GCBox* _pauseOverlay;
  GCElement* _hud;
  GCMenuList* _pauseMenu;
  OptionsScreen* _options;
  NSMutableArray<GCLabel*>* _stars;
  double _bannerUntil;
}

- (instancetype)initWithSongId:(NSString*)songId instrument:(NSString*)instrument difficulty:(NSString*)difficulty mode:(NSString*)mode {
  if ((self = [super init])) {
    _songId = songId.UTF8String;
    _mode = mode.UTF8String;
    _instrument = instrumentFromName(instrument.UTF8String);
    _difficulty = difficultyFromName(difficulty.UTF8String);
    _speed = 1;
    _playerStem = -1;
    _botStrumAt = -1e300;
    _bot = settings().botMode || GCApp.shared.debugBot;
    _lyricIndex = -1;
    _lightIndex = -1;
    _tiltArmed = true;
  }
  return self;
}
- (void)setPracticeStart:(double)start end:(double)end speed:(double)speed loop:(BOOL)loop { _practice = true; _practiceStart = start; _practiceEnd = end; _speed = speed; _loop = loop; }
- (void)setSpeed:(double)speed { _speed = speed > 0 ? speed : 1; }
- (void)setReplayPath:(NSString*)path {
  NSData* data = [NSData dataWithContentsOfFile:path];
  NSDictionary* d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![d isKindOfClass:NSDictionary.class]) return;
  _replay.clear();
  for (NSArray* ev in d[@"events"]) if ([ev isKindOfClass:NSArray.class] && ev.count == 3) _replay.push_back({[ev[0] doubleValue], [ev[1] intValue], [ev[2] intValue]});
  _isReplay = true;
  _bot = false;
  _speed = d[@"speed"] ? [d[@"speed"] doubleValue] : _speed;
}
static const bool kRecordBot = getenv("GC_RECORD_BOT") != nullptr;  // debug: treat the bot as a human for replays/history
- (void)record:(int)type value:(int)value time:(double)t { if (!_isReplay && (!_bot || kRecordBot)) _recording.push_back({t, type, value}); }
- (void)runReplay:(double)t {
  while (_replayPos < _replay.size() && _replay[_replayPos].t <= t) {
    const Rec& r = _replay[_replayPos++];
    switch (r.type) {
      case 0: _frets = r.value; _padFrets = 0; _engine->setFrets(r.value, r.t); break;
      case 1: _engine->strum(r.t); break;
      case 2: _engine->activateStarPower(); break;
      case 3: _padWhammy = r.value / 1000.f; break;
    }
  }
}
- (BOOL)wantsGameView { return YES; }
- (id<MTLTexture>)lastFrameTexture { return self.lastTexture; }

- (double)engineTime { return _mixer->time() - _mixer->outputLatency() - settings().audioOffset / 1000.0; }
- (double)engineTimeAt:(double)eventTime { return [self engineTime] - (GCHostSeconds() - eventTime); }

- (void)enter:(GCStage*)stage {
  _stage = stage;
  GCApp* app = GCApp.shared;
  const SongEntry* entry = Library::instance().byId(_songId);
  std::string err;
  _song = entry ? loadSong(entry->path, &err) : nullptr;
  if (!_song) { fprintf(stderr, "load failed: %s\n", err.c_str()); [app showMainMenu]; return; }
  _track = _song->chart.track(_instrument, _difficulty);
  if (!_track) { [app showMainMenu]; return; }
  EngineOptions eo;
  eo.hitWindow = settings().hitWindow / 1000.0;
  eo.noFail = settings().noFail || _practice;
  _engine = std::make_unique<GameEngine>(_song->chart, *_track, eo);
  if (_practice) _engine->reset(_practiceStart, _practiceEnd);
  __weak GameplayScreen* weakSelf = self;
  _engine->setListener([weakSelf](const EngineEvent& e) { GameplayScreen* self2 = weakSelf; if (self2) self2->_pendingEvents.push_back(e); });  // runs under _engineMutex

  _renderer = std::make_unique<render::Renderer>(app.device);
  if (!_renderer->init(app.metallibPath, &err)) { fprintf(stderr, "renderer: %s\n", err.c_str()); [app showMainMenu]; return; }
  _renderer->setChart(&_song->chart, _track);
  [self loadBackground];
  [self applyRenderSettings];
  const CGSize ds = app.gameView.drawableSize;
  _renderer->resize(int(ds.width), int(ds.height));

  _mixer = std::make_unique<audio::Mixer>();
  if (!_mixer->start(&err)) fprintf(stderr, "audio: %s\n", err.c_str());
  _mixer->setMusicGain(float(settings().musicVolume * settings().masterVolume) * (app.screenshotPath.empty() ? 1.f : 0.f));
  _mixer->setSfxGain(float(settings().sfxVolume * settings().masterVolume));
  for (auto& s : _song->stems) {
    int id = _mixer->addStem(s.stream);
    if ((s.name == "guitar" && (_instrument == Instrument::Guitar || _instrument == Instrument::Coop)) || (s.name == "bass" && _instrument == Instrument::Bass) || (s.name == "rhythm" && _instrument == Instrument::Rhythm) || (s.name == "keys" && _instrument == Instrument::Keys)) _playerStem = id;
  }
  [self buildHud];
  [self warmFonts];
  [self warmHudLayers];
  [self startRange];
  [self startEngineThread];
}

- (void)applyRenderSettings {
  auto& rs = _renderer->settings();
  const auto& s = settings();
  rs.noteSpeed = float(s.noteSpeed);
  rs.leftHanded = s.leftHanded;
  rs.exposure = float(s.exposure);
  rs.saturation = float(s.saturation);
  rs.contrast = float(s.contrast);
  rs.toneMapping = s.toneMapping == "aces" ? 2 : s.toneMapping == "neutral" ? 1 : 0;
  rs.bloom = s.bloom == "off" ? 0.f : s.bloom == "medium" ? 0.35f : s.bloom == "high" ? 0.5f : 0.22f;
  rs.effects = float(s.effectsIntensity);
  rs.reflections = float(s.reflections);
  rs.renderScale = float(s.renderScale);
  rs.reducedMotion = s.reducedMotion;
  rs.cameraPreset = s.cameraPreset == "close" ? 1 : s.cameraPreset == "high" ? 2 : 0;
  if (s.quality == "low") rs.bloom = 0;
  _renderer->setBackgroundMode(s.background == "song" ? 1 : s.background == "none" ? 2 : 0);
}
- (void)loadBackground {
  for (const char* n : {"video.mp4", "video.mov", "video.m4v"}) {
    NSString* path = @((_song->folder + "/" + n).c_str());
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
    AVPlayerItem* item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    _videoOut = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferMetalCompatibilityKey: @YES}];
    [item addOutput:_videoOut];
    _video = [AVPlayer playerWithPlayerItem:item];
    _video.muted = YES;
    _video.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, GCApp.shared.device, nullptr, &_videoCache);
    return;
  }
  for (const char* n : {"background.png", "background.jpg", "background.jpeg"}) {
    NSString* path = @((_song->folder + "/" + n).c_str());
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
    MTKTextureLoader* loader = [[MTKTextureLoader alloc] initWithDevice:GCApp.shared.device];
    NSError* err = nil;
    id<MTLTexture> tex = [loader newTextureWithContentsOfURL:[NSURL fileURLWithPath:path] options:@{MTKTextureLoaderOptionSRGB: @NO, MTKTextureLoaderOptionOrigin: MTKTextureLoaderOriginTopLeft} error:&err];
    if (tex) { _renderer->setBackgroundImage(tex); return; }
  }
}
// keeps the song video following the transport and hands the current frame to the renderer
- (void)syncVideo:(double)t {
  if (!_video || settings().background != "song") return;
  const bool shouldPlay = !_paused && !_finished && !_resuming && t >= 0;
  const double rate = _speed > 0 ? _speed : 1.0;
  if (shouldPlay) {
    const double videoT = CMTimeGetSeconds(_video.currentTime);
    if (_video.rate == 0 || fabs(videoT - t) > 0.25) {
      [_video seekToTime:CMTimeMakeWithSeconds(std::max(0.0, t), 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
      if (_video.rate == 0) [_video playImmediatelyAtRate:float(rate)];
    }
  } else if (_video.rate != 0) [_video pause];
  CMTime now = [_videoOut itemTimeForHostTime:CACurrentMediaTime()];
  if (![_videoOut hasNewPixelBufferForItemTime:now]) return;
  CVPixelBufferRef pb = [_videoOut copyPixelBufferForItemTime:now itemTimeForDisplay:nullptr];
  if (!pb) return;
  CVMetalTextureRef mt = nullptr;
  const size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
  if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _videoCache, pb, nullptr, MTLPixelFormatBGRA8Unorm, w, h, 0, &mt) == kCVReturnSuccess && mt) {
    _videoTex = CVMetalTextureGetTexture(mt);  // the Metal texture keeps the buffer alive while referenced
    _renderer->setBackgroundImage(_videoTex);
    CFRelease(mt);
  }
  CVPixelBufferRelease(pb);
}

- (void)applyLiveSettings {
  [self applyRenderSettings];
  const auto& s = settings();
  if (_mixer) {
    _mixer->setMusicGain(float(s.musicVolume * s.masterVolume) * (GCApp.shared.screenshotPath.empty() ? 1.f : 0.f));
    _mixer->setSfxGain(float(s.sfxVolume * s.masterVolume));
  }
  _bot = s.botMode || GCApp.shared.debugBot;
  [GCApp.shared applySfxGain];
}

- (void)startRange {
  const double rate = _speed > 0 ? _speed : 1.0;
  const int firstIdx = _engine->firstPending();
  const double firstNote = firstIdx < int(_track->notes.size()) ? _track->notes[firstIdx].time : 0;
  const double LEAD = 3.0;
  _startTime = _practice ? std::max(_practiceStart - LEAD * rate, std::min(firstNote, _practiceStart) - LEAD * rate) : std::min(-LEAD, firstNote - LEAD);
  _countdownDone = false;
  _countdownTarget = firstNote;
  _finished = false;
  _engine->setFrets(_frets, _startTime);
  _mixer->play(_startTime, rate);
}

- (void)startEngineThread {
  if (_engineRun) return;
  _engineRun = true;
  _engineThread = std::thread([self] {
    pthread_setname_np("gc.engine");
    double lastWhammy = -1;
    std::vector<InputCmd> q;
    while (_engineRun) {
      {
        std::lock_guard<std::mutex> lk(_engineMutex);
        { std::lock_guard<std::mutex> il(_inputMutex); q.swap(_inputQueue); _inputQueue.clear(); }
        std::stable_sort(q.begin(), q.end(), [](const InputCmd& a, const InputCmd& b) { return a.t < b.t; });
        for (const auto& c : q) {
          if (_isReplay) continue;
          switch (c.type) {
            case 0: _engine->setFrets(c.value, c.t); [self record:0 value:c.value time:c.t]; break;
            case 1: _engine->strum(c.t); [self record:1 value:0 time:c.t]; break;
            case 2: [self record:2 value:0 time:c.t]; _engine->activateStarPower(); break;
          }
        }
        q.clear();
        const float w = _whammyAtomic.load();
        if (w != lastWhammy) { lastWhammy = w; _engine->setWhammy(w); if (!_isReplay && !_bot) [self record:3 value:int(w * 1000) time:[self engineTime]]; }
        if (!_paused && !_finished && !_resuming && _engine) {
          const double t = [self engineTime];
          if (_bot) [self runBot:t];
          if (_isReplay) [self runReplay:t];
          _engine->update(t - 0.03);  // 30 ms grace so an input delivered late still lands inside its window
        }
      }
      usleep(500);
    }
  });
}
- (void)stopEngineThread {
  if (!_engineRun) return;
  _engineRun = false;
  if (_engineThread.joinable()) _engineThread.join();
}
- (void)enqueue:(int)type value:(int)value time:(double)t { std::lock_guard<std::mutex> il(_inputMutex); _inputQueue.push_back({t, type, value}); }

- (void)exit {
  [self stopEngineThread];
  [self closeOptions];
  if (_video) { [_video pause]; _video = nil; _videoOut = nil; _videoTex = nil; }
  if (_videoCache) { CFRelease(_videoCache); _videoCache = nullptr; }
  gc::audio::Sfx::instance().setCrowdLevel(0);
  if (_mixer) _mixer->stop();
  _engine.reset();
  _renderer.reset();
  _mixer.reset();
}

// ------------------------------------------------------------------ HUD
- (GCLabel*)hudLabel:(NSString*)t size:(CGFloat)sz display:(BOOL)d weight:(CGFloat)w color:(uint32_t)c {
  GCLabel* l = GCMakeLabel(t, sz, d, w, c);
  [_hud addSubview:l];
  return l;
}
- (void)buildHud {
  _hud = [[GCElement alloc] initWithFrame:NSZeroRect];
  _hud.left = 0; _hud.right = 0; _hud.top = 0; _hud.bottom = 0;
  [_stage addSubview:_hud];
  const SongEntry* entry = Library::instance().byId(_songId);
  NSString* inst = @(instrumentName(_instrument)); NSString* diff = @(difficultyName(_difficulty));
  GCLabel* title = [self hudLabel:@(entry->meta.name.c_str()) size:34 display:YES weight:700 color:GC_INK]; title.left = 48; title.top = 32;
  GCLabel* sub = [self hudLabel:[NSString stringWithFormat:@"%s · %@ · %@", entry->meta.artist.c_str(), [inst capitalizedString], [diff capitalizedString]] size:14 display:NO weight:400 color:GC_MUTED]; sub.left = 48; sub.top = 80;
  GCLabel* esc = [self hudLabel:_isReplay ? @"REPLAY   ·   Esc   Pause" : @"Esc   Pause" size:15 display:NO weight:400 color:_isReplay ? GC_YELLOW : GC_MUTED]; esc.right = 48; esc.top = 32;
  GCBox* ptrack = [[GCBox alloc] initWithFrame:NSZeroRect]; ptrack.left = 48; ptrack.right = 48; ptrack.top = 118; ptrack.height = 3; ptrack.fill = GCColor(GC_RULE); [_hud addSubview:ptrack];
  _progress = [[GCBox alloc] initWithFrame:NSZeroRect]; _progress.left = 0; _progress.top = 0; _progress.height = 3; _progress.width = 0; _progress.fill = GCColor(GC_INK); [ptrack addSubview:_progress];
  GCLabel* scoreLbl = [self hudLabel:@"SCORE" size:14 display:NO weight:400 color:GC_MUTED]; scoreLbl.tracking = 0.16; scoreLbl.left = 80; scoreLbl.top = 206;
  _score = [self hudLabel:@"0" size:76 display:YES weight:800 color:GC_INK]; _score.left = 80; _score.top = 232; _score.lineHeight = 78;
  _stars = [NSMutableArray new];
  for (int i = 0; i < 5; i++) { GCLabel* s = [self hudLabel:@"★" size:26 display:NO weight:400 color:GC_RULE]; s.left = 80 + i * 30; s.top = 322; [_stars addObject:s]; }
  _streak = [self hudLabel:@"0" size:96 display:YES weight:800 color:GC_INK]; _streak.left = 80; _streak.top = 436; _streak.lineHeight = 96;
  GCLabel* streakLbl = [self hudLabel:@"NOTE STREAK" size:14 display:NO weight:400 color:GC_MUTED]; streakLbl.tracking = 0.17; streakLbl.left = 80; streakLbl.top = 540;
  _streakMsg = [self hudLabel:@"" size:16 display:NO weight:400 color:GC_YELLOW]; _streakMsg.left = 80; _streakMsg.top = 572; _streakMsg.uppercase = YES;
  _mult = [self hudLabel:@"1×" size:112 display:YES weight:800 color:GC_INK]; _mult.right = 90; _mult.top = 240; _mult.width = 220; _mult.align = NSTextAlignmentCenter; _mult.lineHeight = 112;
  _multLbl = [self hudLabel:@"STAR POWER" size:14 display:NO weight:400 color:GC_MUTED]; _multLbl.tracking = 0.16; _multLbl.right = 90; _multLbl.top = 364; _multLbl.width = 220; _multLbl.align = NSTextAlignmentCenter;
  GCBox* spTrack = [[GCBox alloc] initWithFrame:NSZeroRect]; spTrack.right = 106; spTrack.top = 394; spTrack.width = 188; spTrack.height = 8; spTrack.fill = GCColor(GC_RULE); [_hud addSubview:spTrack];
  _spBar = [[GCBox alloc] initWithFrame:NSZeroRect]; _spBar.left = 0; _spBar.top = 0; _spBar.height = 8; _spBar.width = 0; _spBar.fill = GCColor(GC_YELLOW); [spTrack addSubview:_spBar];
  GCLabel* rockLbl = [self hudLabel:@"ROCK METER" size:14 display:NO weight:400 color:GC_MUTED]; rockLbl.tracking = 0.16; rockLbl.right = 130; rockLbl.top = 488; rockLbl.width = 140; rockLbl.align = NSTextAlignmentCenter;
  GCBox* rockTrack = [[GCBox alloc] initWithFrame:NSZeroRect]; rockTrack.right = 191; rockTrack.top = 526; rockTrack.width = 18; rockTrack.height = 182; rockTrack.fill = GCColor(GC_RULE); [_hud addSubview:rockTrack];
  _rockFill = [[GCBox alloc] initWithFrame:NSZeroRect]; _rockFill.left = 0; _rockFill.bottom = 0; _rockFill.width = 18; _rockFill.height = 91; _rockFill.fill = GCColor(GC_YELLOW); [rockTrack addSubview:_rockFill];
  _rockState = [self hudLabel:@"STEADY" size:26 display:YES weight:700 color:GC_INK]; _rockState.right = 130; _rockState.top = 728; _rockState.width = 140; _rockState.align = NSTextAlignmentCenter;
  _time = [self hudLabel:@"00:00 / 00:00" size:15 display:NO weight:400 color:GC_MUTED]; _time.left = 48; _time.bottom = 48;
  GCLabel* hints = [self hudLabel:[NSString stringWithFormat:@"%s / Tilt   Star power   ·   %s   Whammy", keyName(settings().keys.starPower).c_str(), keyName(settings().keys.whammy).c_str()] size:15 display:NO weight:400 color:GC_MUTED]; hints.right = 48; hints.bottom = 48;
  // transient labels keep a fixed frame so AppKit reuses their layer backing store instead of reallocating on every text change
  _solo = [self hudLabel:@"" size:56 display:YES weight:800 color:GC_INK]; _solo.centerX = YES; _solo.top = 140; _solo.opacityValue = 0.002; _solo.fitContent = NO; _solo.width = 420; _solo.height = 70; _solo.align = NSTextAlignmentCenter;
  _banner = [self hudLabel:@"" size:72 display:YES weight:800 color:GC_INK]; _banner.centerX = YES; _banner.top = 300; _banner.opacityValue = 0.002; _banner.fitContent = NO; _banner.text = @"Star Power!"; _banner.width = 980; _banner.height = 92; _banner.align = NSTextAlignmentCenter;
  _lyrics = [self hudLabel:@"" size:20 display:NO weight:400 color:GC_INK]; _lyrics.centerX = YES; _lyrics.top = 770; _lyrics.fitContent = NO; _lyrics.width = 1100; _lyrics.height = 28; _lyrics.align = NSTextAlignmentCenter;
  // timing readout: left column under the streak, in the HUD's kicker / display / meter language
  _timingBox = [[GCElement alloc] initWithFrame:NSZeroRect]; _timingBox.left = 80; _timingBox.top = 608; _timingBox.width = 300; _timingBox.height = 120; _timingBox.opacityValue = 0.002; [_hud addSubview:_timingBox];
  GCLabel* tk = GCMakeLabel(@"TIMING", 14, NO, 400, GC_MUTED); tk.tracking = 0.16; tk.left = 0; tk.top = 0; [_timingBox addSubview:tk];
  _timing = GCMakeLabel(@"PERFECT", 34, YES, 800, GC_GREEN); _timing.left = 0; _timing.top = 20; _timing.fitContent = NO; _timing.width = 200; _timing.height = 40; _timing.lineHeight = 38; [_timingBox addSubview:_timing];
  _timingMs = GCMakeLabel(@"+0 ms", 15, NO, 400, GC_MUTED); _timingMs.left = 0; _timingMs.top = 62; _timingMs.fitContent = NO; _timingMs.width = 200; _timingMs.height = 20; [_timingBox addSubview:_timingMs];
  GCBox* tTrack = [[GCBox alloc] initWithFrame:NSZeroRect]; tTrack.left = 0; tTrack.top = 94; tTrack.width = 188; tTrack.height = 4; tTrack.fill = GCColor(GC_RULE); [_timingBox addSubview:tTrack];
  _timingZone = [[GCBox alloc] initWithFrame:NSZeroRect]; _timingZone.top = 94; _timingZone.height = 4; _timingZone.fill = GCColor(GC_GREEN, 0.45); [_timingBox addSubview:_timingZone];
  GCBox* tick = [[GCBox alloc] initWithFrame:NSZeroRect]; tick.left = 93; tick.top = 90; tick.width = 2; tick.height = 12; tick.fill = GCColor(GC_MUTED); [_timingBox addSubview:tick];
  _timingMarker = [[GCBox alloc] initWithFrame:NSZeroRect]; _timingMarker.top = 88; _timingMarker.width = 6; _timingMarker.height = 16; _timingMarker.fill = GCColor(GC_INK); _timingMarker.left = 91; [_timingBox addSubview:_timingMarker];
  GCLabel* tl = GCMakeLabel(@"EARLY", 11, NO, 400, GC_MUTED); tl.tracking = 0.12; tl.left = 0; tl.top = 106; [_timingBox addSubview:tl];
  GCLabel* tr = GCMakeLabel(@"LATE", 11, NO, 400, GC_MUTED); tr.tracking = 0.12; tr.left = 160; tr.top = 106; [_timingBox addSubview:tr];
  _countdown = [self hudLabel:@"" size:120 display:YES weight:800 color:GC_YELLOW]; _countdown.centerX = YES; _countdown.top = 380; _countdown.fitContent = NO; _countdown.width = 640; _countdown.height = 150; _countdown.align = NSTextAlignmentCenter;
}

// Rasterises the display font at every HUD size once so the first banner / countdown change does not
// stall the frame on glyph generation.
- (void)warmFonts {
  const CGFloat bs = GCApp.shared.window.backingScaleFactor ?: 2;
  const CGFloat st = _stage.scale;
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:int(256 * bs) pixelsHigh:int(256 * bs) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext* ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [NSGraphicsContext setCurrentContext:ctx];
  CGContextScaleCTM(ctx.CGContext, bs, bs);
  NSString* glyphs = @"0123456789,.%×!·ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
  for (CGFloat size : {120.0, 112.0, 96.0, 76.0, 72.0, 56.0, 48.0, 34.0, 26.0}) {
    for (CGFloat w : {700.0, 800.0}) [[[NSAttributedString alloc] initWithString:glyphs attributes:@{NSFontAttributeName: GCDisplayFont(size * st, w)}] drawAtPoint:NSZeroPoint];
  }
  for (CGFloat size : {14.0, 15.0, 16.0, 20.0}) [[[NSAttributedString alloc] initWithString:glyphs attributes:@{NSFontAttributeName: GCBodyFont(size * st, 400)}] drawAtPoint:NSZeroPoint];
  [NSGraphicsContext restoreGraphicsState];
}

// The first display of a text layer costs ~15-20 ms in AppKit (backing store + glyph runs). Pay it now, while
// loading, for every label that only changes occasionally during play.
- (void)warmHudLayers {
  NSArray<GCLabel*>* labels = @[_banner, _solo, _lyrics, _streakMsg, _countdown, _mult, _multLbl, _rockState, _time, _timing, _timingMs];
  NSArray<NSString*>* samples = @[@"100 Note Streak!", @"100%", @"Warm up the lyric line", @"Untouchable.", @"ROCK!", @"4×", @"STAR POWER ACTIVE", @"ON FIRE", @"00:00 / 00:00   ·   INTRO", @"PERFECT", @"+12 ms"];
  NSMutableArray<NSString*>* saved = [NSMutableArray new];
  NSMutableArray<NSNumber*>* savedAlpha = [NSMutableArray new];
  for (NSUInteger i = 0; i < labels.count; i++) { [saved addObject:labels[i].text ?: @""]; [savedAlpha addObject:@(labels[i].opacityValue)]; labels[i].text = samples[i]; labels[i].opacityValue = 0.002; }
  [_stage relayout];
  [GCApp.shared.window displayIfNeeded];
  [CATransaction flush];
  for (NSUInteger i = 0; i < labels.count; i++) { labels[i].text = saved[i]; labels[i].opacityValue = savedAlpha[i].doubleValue; }
  [_stage relayout];
  [GCApp.shared.window displayIfNeeded];
  [CATransaction flush];
}

- (void)showBanner:(NSString*)text sp:(BOOL)sp {
  _banner.text = text;
  _banner.color = GCColor(sp ? GC_YELLOW : GC_INK);
  _banner.opacityValue = 1;
  static const bool clockLog = getenv("GC_CLOCKLOG") != nullptr;
  if (clockLog) fprintf(stderr, "banner '%s'\n", text.UTF8String);
  _bannerUntil = GCHostSeconds() + 1.4;
}

- (void)updateHud:(double)t {
  const auto& st = _stats;
  _score.text = fmtScore(st.score);
  _streak.text = [NSString stringWithFormat:@"%d", st.streak];
  _streakMsg.text = st.streak >= 100 ? @"Untouchable." : st.streak >= 50 ? @"Keep it going." : st.streak >= 20 ? @"Locked in." : (st.streak == 0 && st.notesMissed > 0) ? @"Shake it off." : @"";
  _mult.text = [NSString stringWithFormat:@"%d×", st.multiplier];
  _mult.color = GCColor(st.spActive ? GC_YELLOW : GC_INK);
  _multLbl.text = st.spActive ? @"STAR POWER ACTIVE" : st.starPower >= 0.5 ? @"STAR POWER READY · SPACE" : @"STAR POWER";
  _multLbl.color = GCColor(st.spActive || st.starPower >= 0.5 ? GC_YELLOW : GC_MUTED);
  _spBar.width = 188 * std::max(0.0, std::min(1.0, st.starPower));
  _rockFill.height = 182 * std::max(0.0, std::min(1.0, st.rockMeter));
  _rockFill.fill = GCColor(st.rockMeter < 0.3 ? GC_RED : GC_YELLOW);
  _rockState.text = st.failed ? @"FAILED" : st.rockMeter >= 0.8 ? @"ON FIRE" : st.rockMeter >= 0.5 ? @"STEADY" : st.rockMeter >= 0.3 ? @"SHAKY" : @"DANGER";
  const int stars = starRating(st.score, _engine->maxBaseScore(), false);
  for (int i = 0; i < 5; i++) _stars[i].color = GCColor(i < stars ? GC_YELLOW : GC_RULE);
  const double len = _song->chart.chartLength > 0 ? _song->chart.chartLength : 1;
  _progress.width = std::max<CGFloat>(0, std::min<CGFloat>(1, t / len)) * (_stage.stageSize.width - 96);
  NSString* section = @(_engine->currentSectionName().c_str());
  _time.text = [NSString stringWithFormat:@"%@ / %@%@", fmtTime(t), fmtTime(len), section.length ? [NSString stringWithFormat:@"   ·   %@", [section uppercaseString]] : @""];
  if (_engine->soloActive()) {
    const int total = _engine->soloTotal();
    _solo.text = [NSString stringWithFormat:@"%d%%", total ? int(std::lround(100.0 * _engine->soloHit() / total)) : 100];
    _solo.opacityValue = 1;
  } else _solo.opacityValue = 0.002;
  if (_banner.opacityValue > 0.5 && GCHostSeconds() > _bannerUntil) _banner.opacityValue = 0.002;
  if (_timingBox.opacityValue > 0.5 && GCHostSeconds() > _timingUntil) _timingBox.opacityValue = 0.4;  // keep the last reading, dimmed
  // crowd bed follows the rock meter and the streak; star power ready chime once per fill
  const float crowdTarget = float(std::max(0.0, (st.rockMeter - 0.45) / 0.55)) * (0.6f + 0.4f * std::min(1.f, st.streak / 50.f)) + (st.spActive ? 0.25f : 0.f);
  _crowdLevel += (crowdTarget - _crowdLevel) * 0.05f;
  audio::Sfx::instance().setCrowdLevel(_paused || _finished ? 0.f : _crowdLevel);
  if (st.starPower >= 0.5 && !st.spActive) { if (!_spReadyChimed) { _spReadyChimed = true; audio::Sfx::instance().playStarPowerReady(); } }
  else _spReadyChimed = false;
  const auto& lyrics = _song->chart.lyrics;
  if (settings().showLyrics && !lyrics.empty()) {
    int li = _lyricIndex;
    while (li + 1 < int(lyrics.size()) && lyrics[li + 1].time <= t) li++;
    if (li != _lyricIndex) {
      _lyricIndex = li;
      std::string line;
      for (int i = std::max(0, li - 6); i <= li; i++) {
        std::string w;
        for (char c : lyrics[i].text) if (c != '-' && c != '=' && c != '#' && c != '^' && c != '+') w += c;
        if (!line.empty()) line += ' ';
        line += w;
      }
      _lyrics.text = @(line.c_str());
    }
  } else if (_lyrics.text.length) _lyrics.text = @"";
  if (!_countdownDone) {
    const double remain = _countdownTarget - t;
    _countdown.text = remain > 2.2 ? @"3" : remain > 1.4 ? @"2" : remain > 0.6 ? @"1" : remain > -0.4 ? @"ROCK!" : @"";
    if (remain <= -0.4) _countdownDone = true;
  }
  [_stage relayout];
}

// ------------------------------------------------------------------ events
- (void)onEngineEvent:(const EngineEvent&)e {
  const bool mute = settings().muteOnMiss;
  switch (e.type) {
    case EngineEvent::Type::Hit: {
      const float off = [&] { std::lock_guard<std::mutex> lk(_engineMutex); return _engine->hitOffset()[e.index] * 1000.f; }();
      _renderer->hitEffect(_track->notes[e.index].frets, 1.f - std::min(1.f, fabsf(off) / float(std::max(1.0, settings().hitWindow))));
      _offsets.push_back(off);
      if (settings().timingFeedback) {
        const double perfect = settings().perfectWindow, win = std::max(1.0, settings().hitWindow);
        const bool isPerfect = fabsf(off) <= perfect;
        const uint32_t col = isPerfect ? GC_GREEN : off < 0 ? GC_BLUE : GC_ORANGE;
        _timing.text = isPerfect ? @"PERFECT" : off < 0 ? @"EARLY" : @"LATE";
        _timing.color = GCColor(col);
        _timingMs.text = [NSString stringWithFormat:@"%+d ms", int(lroundf(off))];
        const double zoneW = std::min(188.0, 188.0 * perfect / win);
        _timingZone.left = 94 - zoneW / 2; _timingZone.width = zoneW;
        const double pos = 94 + std::max(-94.0, std::min(94.0, off / win * 94.0));
        _timingMarker.left = pos - 3; _timingMarker.fill = GCColor(col);
        _timingBox.opacityValue = 1;
        _timingUntil = GCHostSeconds() + 0.6;
      }
      if (mute && _playerStem >= 0) _mixer->setStemGain(_playerStem, 1.f);
      { std::lock_guard<std::mutex> lk(_engineMutex); _stats = _engine->stats(); }
      if (_stats.streak > 0 && _stats.streak % 50 == 0) [self showBanner:[NSString stringWithFormat:@"%d Note Streak!", _stats.streak] sp:NO];
      break;
    }
    case EngineEvent::Type::Miss:
      _missTimes.push_back(_track->notes[e.index].time);
      if (getenv("GC_BOTLOG")) { const auto& n = _track->notes[e.index]; fprintf(stderr, "miss idx=%d t=%.3f frets=%d type=%d forced=%d tap=%d overstrum=%d | now=%.3f held=%d lastStrum=%.3f prev(idx-1) t=%.3f frets=%d len=%.2f\n", e.index, n.time, n.frets, (int)n.type, (int)n.forced, (int)n.tap, (int)e.overstrum, [self engineTime], _engine->fretsHeld(), _botStrumAt, e.index > 0 ? _track->notes[e.index - 1].time : 0.0, e.index > 0 ? _track->notes[e.index - 1].frets : 0, e.index > 0 ? _track->notes[e.index - 1].endTime - _track->notes[e.index - 1].time : 0.0); }
      if (e.overstrum) { _renderer->missEffect(); audio::Sfx::instance().playMiss(); }
      platform::rumble(0.25f, 0.05f);
      if (mute && _playerStem >= 0) _mixer->setStemGain(_playerStem, 0.f);
      break;
    case EngineEvent::Type::Overstrum:
      _renderer->missEffect();
      audio::Sfx::instance().playMiss();
      platform::rumble(0.35f, 0.06f);
      if (mute && _playerStem >= 0) _mixer->setStemGain(_playerStem, 0.f);
      break;
    case EngineEvent::Type::SpEnded: _renderer->starPowerEnded(); audio::Sfx::instance().playStarPowerEnd(); break;
    case EngineEvent::Type::Multiplier: if (e.multiplier >= 4 && !_stats.spActive) [self showBanner:@"4× Multiplier" sp:NO]; break;
    case EngineEvent::Type::SpActivated:
      _renderer->starPowerActivated();
      audio::Sfx::instance().playStarPowerActivate();
      platform::rumble(1.f, 0.35f);
      [self showBanner:@"Star Power!" sp:YES];
      break;
    case EngineEvent::Type::SoloEnd:
      [self showBanner:e.soloPercent >= 100 ? @"Perfect Solo!" : [NSString stringWithFormat:@"Solo %d%%", e.soloPercent] sp:NO];
      if (e.soloPercent >= 90) audio::Sfx::instance().playCrowdCheer(0.8f);
      break;
    case EngineEvent::Type::Fail:
      _finished = true;
      _mixer->pause();
      audio::Sfx::instance().playFail();
      platform::rumble(0.8f, 0.6f);
      [self showBanner:@"Song failed" sp:NO];
      _finishAt = GCHostSeconds() + 1.8;
      break;
    case EngineEvent::Type::End:
      _finished = true;
      if (_practice) {
        const auto& st = _stats;
        [self showBanner:[NSString stringWithFormat:@"%d%% — %d/%d", st.notesTotal ? int(std::lround(100.0 * st.notesHit / st.notesTotal)) : 100, st.notesHit, st.notesTotal] sp:NO];
        if (_loop) { _finishAt = -1; [self performSelector:@selector(restartRange) withObject:nil afterDelay:1.2]; }
        else _finishAt = GCHostSeconds() + 1.5;
      } else _finishAt = GCHostSeconds() + 1.5;
      break;
    default: break;
  }
}

- (void)restartRange {
  _mixer->pause();
  { std::lock_guard<std::mutex> lk(_engineMutex); _engine->reset(_practiceStart, _practiceEnd); [self startRange]; }
}

- (void)activateStarPower { [self enqueue:2 value:0 time:[self engineTime]]; }

- (void)runBot:(double)t {
  static const double jitter = getenv("GC_BOT_JITTER") ? atof(getenv("GC_BOT_JITTER")) / 1000.0 : 0;  // ms, debug: random early/late hits
  static double nextOffset = 0;
  // handle every note that became due this frame; after a long frame the strum is dated at the note itself
  for (int guard = 0; guard < 64; guard++) {
    const int idx = _engine->firstPending();
    if (idx >= int(_track->notes.size())) return;
    const auto& note = _track->notes[idx];
    const double due = note.time - 0.004 + nextOffset;
    if (t < due) break;
    const double at = (t - due > 0.03) ? std::max(_botStrumAt + 0.011, note.time + nextOffset) : t;
    if (_engine->fretsHeld() != (note.frets & 0b11111)) { _engine->setFrets(note.frets & 0b11111, at); [self record:0 value:(note.frets & 0b11111) time:at]; }
    if (_engine->firstPending() != idx) continue;  // the fret change alone hit it (HOPO / tap)
    if (at - _botStrumAt <= 0.01) break;
    _engine->strum(at); [self record:1 value:0 time:at]; _botStrumAt = at;
    nextOffset = jitter > 0 ? (double(arc4random_uniform(2000)) / 1000.0 - 1.0) * jitter : 0;
    if (_engine->firstPending() == idx) break;  // genuinely not hit; do not spin
  }
  if (_engine->stats().starPower >= 0.5 && !_engine->stats().spActive) _engine->activateStarPower();
}

- (void)finish {
  [self stopEngineThread];
  const auto& st = _engine->stats();
  const bool failed = st.failed;
  const bool fc = !failed && st.notesMissed == 0 && st.overstrums == 0 && st.notesHit == st.notesTotal;
  const double maxBase = _engine->maxBaseScore();
  const int stars = failed ? 0 : starRating(st.score, maxBase, fc);
  const double acc = st.notesTotal ? double(st.notesHit) / st.notesTotal : 1;
  fprintf(stderr, "result: score=%d maxBase=%.0f ratio=%.3f hit=%d/%d missed=%d overstrums=%d fc=%d stars=%d spPhrases=%d/%d\n", st.score, maxBase, maxBase > 0 ? st.score / maxBase : 0.0, st.notesHit, st.notesTotal, st.notesMissed, st.overstrums, (int)fc, stars, st.spPhrasesHit, st.spPhrasesTotal);
  if (!failed && acc >= 0.95) audio::Sfx::instance().playCrowdCheer(1.f);
  BOOL newRecord = NO;
  const bool fullSpeed = _speed <= 0 || fabs(_speed - 1.0) < 1e-6;
  NSString* replayPath = nil;
  if ((!_bot || kRecordBot) && !_isReplay && _mode != "practice") {
    // write the input stream so the run can be watched back
    NSString* dir = [NSString stringWithFormat:@"%s/replays", supportDir().c_str()];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray* events = [NSMutableArray new];
    for (const auto& r : _recording) [events addObject:@[@(r.t), @(r.type), @(r.value)]];
    replayPath = [NSString stringWithFormat:@"%@/%s-%s-%s-%lld.json", dir, _songId.c_str(), instrumentName(_instrument), difficultyName(_difficulty), (long long)[NSDate date].timeIntervalSince1970];
    NSData* json = [NSJSONSerialization dataWithJSONObject:@{@"songId": @(_songId.c_str()), @"instrument": @(instrumentName(_instrument)), @"difficulty": @(difficultyName(_difficulty)), @"speed": @(_speed > 0 ? _speed : 1.0), @"score": @(st.score), @"events": events} options:0 error:nil];
    if (json) [json writeToFile:replayPath atomically:YES];
    HistoryEntry h;
    h.date = [NSDate date].timeIntervalSince1970; h.score = st.score; h.stars = stars; h.accuracy = acc; h.speed = _speed > 0 ? _speed : 1.0; h.fullCombo = fc; h.replay = replayPath.UTF8String;
    Library::instance().addHistory(_songId, _instrument, _difficulty, h);
  }
  if (!failed && (!_bot || kRecordBot) && !_isReplay && _mode != "practice" && fullSpeed) {
    ScoreRecord r;
    r.score = st.score; r.stars = stars; r.accuracy = acc; r.notesHit = st.notesHit; r.notesTotal = st.notesTotal; r.longestStreak = st.longestStreak; r.fullCombo = fc; r.date = [NSDate date].timeIntervalSince1970;
    newRecord = Library::instance().saveScore(_songId, _instrument, _difficulty, r);
    if (_mode == "career") Library::instance().recordCareer(_instrument, _difficulty, _songId, std::max(1, stars));
  }
  NSMutableDictionary* sections = [NSMutableDictionary new];
  NSMutableArray* secList = [NSMutableArray new];
  for (size_t i = 0; i < st.sections.size(); i++) {
    const auto& s = st.sections[i];
    const auto& cs = _song->chart.sections;
    const double start = i < cs.size() ? cs[i].time : 0, end = i + 1 < cs.size() ? cs[i + 1].time : _song->chart.chartLength;
    [secList addObject:@{@"name": @(s.name.c_str()), @"hit": @(s.hit), @"total": @(s.total), @"start": @(start), @"end": @(end)}];
  }
  NSMutableArray* offs = [NSMutableArray new];
  for (float o : _offsets) [offs addObject:@(o)];
  NSMutableArray* misses = [NSMutableArray new];
  for (double m : _missTimes) [misses addObject:@(m)];
  NSMutableArray* phrases = [NSMutableArray new];
  { double start = -1; int cur = -1;
    for (const auto& n : _track->notes) {
      if (n.spPhrase != cur) { if (cur >= 0 && start >= 0) [phrases addObject:@[@(start), @(n.time)]]; cur = n.spPhrase; start = n.spPhrase >= 0 ? n.time : -1; }
    }
    if (cur >= 0 && start >= 0) [phrases addObject:@[@(start), @(_track->notes.back().endTime)]]; }
  sections[@"list"] = secList;
  NSDictionary* result = @{@"songId": @(_songId.c_str()), @"instrument": @(instrumentName(_instrument)), @"difficulty": @(difficultyName(_difficulty)), @"mode": @(_mode.c_str()),
                           @"score": @(st.score), @"stars": @(stars), @"fullCombo": @(fc), @"failed": @(failed), @"accuracy": @(acc), @"notesHit": @(st.notesHit), @"notesTotal": @(st.notesTotal), @"notesMissed": @(st.notesMissed),
                           @"longestStreak": @(st.longestStreak), @"overstrums": @(st.overstrums), @"spHit": @(st.spPhrasesHit), @"spTotal": @(st.spPhrasesTotal), @"maxBase": @(maxBase), @"newRecord": @(newRecord), @"sections": secList,
                           @"practiceStart": @(_practiceStart), @"practiceEnd": @(_practiceEnd), @"speed": @(_speed > 0 ? _speed : 1.0), @"loop": @(_loop), @"offsets": offs, @"hitWindow": @(settings().hitWindow), @"perfectWindow": @(settings().perfectWindow), @"bot": @(_bot || _isReplay), @"replay": replayPath ?: @"", @"isReplay": @(_isReplay), @"missTimes": misses, @"spPhrases": phrases, @"length": @(_song->chart.chartLength)};
  [GCApp.shared showScreen:[[ResultsScreen alloc] initWithResult:result]];
}

// ------------------------------------------------------------------ frame
- (void)drawableSizeChanged:(CGSize)size { if (_renderer) _renderer->resize(int(size.width), int(size.height)); }

- (void)renderFrame:(MTKView*)view {
  if (!_engine || !_renderer) return;
  const double now = GCHostSeconds();
  const double dt = _lastFrame ? std::min(0.1, now - _lastFrame) : 1.0 / 60;
  _lastFrame = now;
  const double t = [self engineTime];
  static double secA = 0, secB = 0, secC = 0, secD = 0, secE = 0;  // previous frame: engine, hud, renderer update, encode, total
  const double f0 = GCHostSeconds();
  static const bool stallDebug = getenv("GC_STALL") != nullptr;  // debug: freeze the main thread 300 ms every 10 s
  if (stallDebug) { static double lastStall = 0; if (now - lastStall > 10) { lastStall = now; usleep(300000); } }
  // input events that queued up during a long frame carry their own timestamps; hand them to the engine thread now
  for (int n = 0; n < 64; n++) {
    NSEvent* ev = [NSApp nextEventMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged) untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES];
    if (!ev) break;
    [NSApp sendEvent:ev];
  }
  std::vector<EngineEvent> events;
  {
    std::lock_guard<std::mutex> lk(_engineMutex);
    static const double spAt = getenv("GC_SP_AT") ? atof(getenv("GC_SP_AT")) : -1;  // debug: force star power at this song time
    static bool spFired = false;
    if (spAt >= 0 && !spFired && t >= spAt && !_paused) { spFired = true; _engine->mutableStats().starPower = 1; _engine->activateStarPower(); }
    events.swap(_pendingEvents);
    _stats = _engine->stats();
  }
  for (const auto& e : events) [self onEngineEvent:e];
  if (!_paused && !_finished && !_resuming && GCApp.shared.debugPauseAt > 0 && t >= GCApp.shared.debugPauseAt) { GCApp.shared.debugPauseAt = 0; [self pause]; [GCApp.shared runDebugActions]; }
  if (_finished && _finishAt > 0 && now >= _finishAt) { _finishAt = 0; [self finish]; return; }
  static const float debugWhammy = getenv("GC_WHAMMY") ? float(atof(getenv("GC_WHAMMY"))) : 0.f;
  const float whammy = std::max({_whammyKey ? 1.f : 0.f, _padWhammy, debugWhammy});
  _whammyAtomic = whammy;
  const auto& st = _stats;
  if (_playerStem >= 0) _mixer->setStemDetune(_playerStem, (st.spActive || st.starPower > 0) && !_paused ? -whammy * 0.5f * 120.f : 0.f);
  const double f1 = GCHostSeconds();
  { std::lock_guard<std::mutex> lk(_engineMutex); [self updateHud:t]; }
  const double f2 = GCHostSeconds();
  id<CAMetalDrawable> drawable = view.currentDrawable;
  if (!drawable) return;  // skip the whole frame so the renderer's in-flight fence stays balanced
  static const bool clockLog = getenv("GC_CLOCKLOG") != nullptr;
  if (clockLog && !_paused) {
    static double prevT = 0, prevH = 0, minD = 1e9, maxD = -1e9, minH = 1e9, maxH = -1e9; static int n = 0, back = 0; static bool have = false;
    if (have) {
      const double d = t - prevT, h = now - prevH;
      minD = std::min(minD, d); maxD = std::max(maxD, d); minH = std::min(minH, h); maxH = std::max(maxH, h);
      if (d < 0) back++;
      if (h > 0.025 && n > 120) fprintf(stderr, "hitch %.1f ms at song t=%.2f wall %.2f s (streak %d) prev frame: engine %.1f hud %.1f rupdate %.1f encode %.1f total %.1f ms\n", h * 1000, t, now - GCApp.shared.startedAt, _engine->stats().streak, secA * 1000, secB * 1000, secC * 1000, secD * 1000, secE * 1000);
      static double hudSum = 0; hudSum += secB;
      if (++n % 120 == 0) {
        fprintf(stderr, "clock[%d-%d] fps=%ld song dt %.2f..%.2f ms  wall dt %.2f..%.2f ms  backwards=%d  hud avg %.2f ms\n", n - 120, n, (long)view.preferredFramesPerSecond, minD * 1000, maxD * 1000, minH * 1000, maxH * 1000, back, hudSum / 120 * 1000);
        minD = minH = 1e9; maxD = maxH = -1e9; hudSum = 0;
      }
    }
    prevT = t; prevH = now; have = true;
  }
  const double fv0 = GCHostSeconds();
  [self syncVideo:t];
  {
    const auto& cues = _song->chart.lighting;
    const double vt = t + (settings().audioOffset - settings().videoOffset) / 1000.0;
    while (_lightIndex + 1 < int(cues.size()) && cues[_lightIndex + 1].time <= vt) { _lightIndex++; if (!_paused) _renderer->lightingEvent(cues[_lightIndex].name); }
  }
  const double fv1 = GCHostSeconds();
  render::FrameInput in;
  in.songTime = t + (settings().audioOffset - settings().videoOffset) / 1000.0;
  in.dt = float(_paused ? 0 : dt);
  in.heldFrets = [&] { std::lock_guard<std::mutex> lk(_engineMutex); return _engine->fretsHeld(); }();
  in.whammy = whammy;
  in.engine = _engine.get();
  { std::lock_guard<std::mutex> lk(_engineMutex); _renderer->update(in); }
  const double f3 = GCHostSeconds();
  if (clockLog && f3 - f2 > 0.02) fprintf(stderr, "slow rupdate %.1f ms: hud->drawable %.1f, video %.1f, renderer update %.1f (gpu wait inside) at song t=%.2f\n", (f3 - f2) * 1000, (fv0 - f2) * 1000, (fv1 - fv0) * 1000, (f3 - fv1) * 1000, t);
  id<MTLCommandBuffer> cmd = [GCApp.shared.queue commandBuffer];
  _renderer->draw(cmd, drawable.texture);
  self.lastTexture = drawable.texture;
  [cmd commit];
  [cmd waitUntilScheduled];
  [drawable present];  // presentsWithTransaction: present from the main thread inside the CA transaction
  const double f4 = GCHostSeconds();
  secA = f1 - f0; secB = f2 - f1; secC = f3 - f2; secD = f4 - f3; secE = f4 - f0;
  if (!GCApp.shared.screenshotPath.empty()) [cmd waitUntilCompleted];
}

// ------------------------------------------------------------------ input
- (int)fretForKey:(unsigned short)code {
  const auto& k = settings().keys;
  for (int i = 0; i < 5; i++) if (k.frets[i] == code) return i;
  return -1;
}
- (void)keyDown:(NSEvent*)ev {
  if (ev.isARepeat || !_engine) return;
  if (_options) { [_options keyDown:ev]; return; }
  const auto& k = settings().keys;
  const double t = [self engineTimeAt:ev.timestamp];
  if (_paused) return;  // menu actions handle the pause overlay
  const int fret = [self fretForKey:ev.keyCode];
  if (fret >= 0) { _frets |= 1 << fret; [self syncFrets:t]; return; }
  if (_isReplay && ev.keyCode != k.pause) return;
  if (ev.keyCode == k.strumUp || ev.keyCode == k.strumDown) [self enqueue:1 value:0 time:t];
  else if (ev.keyCode == k.starPower) [self enqueue:2 value:0 time:t];
  else if (ev.keyCode == k.pause) { [self pause]; _pausedByThisKey = _paused; }  // the same key event also arrives as a "back" menu action
  else if (ev.keyCode == k.whammy) { _whammyKey = true; if (getenv("GC_CLOCKLOG")) fprintf(stderr, "whammy (key) down at t=%.2f\n", t); }
}
- (void)keyUp:(NSEvent*)ev {
  if (!_engine) return;
  const int fret = [self fretForKey:ev.keyCode];
  if (fret >= 0) { _frets &= ~(1 << fret); [self syncFrets:[self engineTimeAt:ev.timestamp]]; }
  else if (ev.keyCode == settings().keys.whammy) _whammyKey = false;
}
// Modifier keys report their state through flagsChanged; derive pressed/released from the device-dependent flag of that key.
static bool modifierDown(NSEvent* ev) {
  const NSUInteger f = ev.modifierFlags;
  switch (ev.keyCode) {
    case 56: return f & 0x0002;  // left shift
    case 60: return f & 0x0004;  // right shift
    case 59: return f & 0x0001;  // left control
    case 62: return f & 0x2000;  // right control
    case 58: return f & 0x0020;  // left option
    case 61: return f & 0x0040;  // right option
    case 55: return f & 0x0008;  // left command
    case 54: return f & 0x0010;  // right command
    case 57: return f & NSEventModifierFlagCapsLock;
    default: return false;
  }
}
- (void)flagsChanged:(NSEvent*)ev {
  if (!_engine) return;
  const bool down = modifierDown(ev);
  const auto& k = settings().keys;
  const double t = [self engineTimeAt:ev.timestamp];
  if (ev.keyCode == k.whammy) { _whammyKey = down; if (getenv("GC_CLOCKLOG")) fprintf(stderr, "whammy (flags) %d at t=%.2f\n", (int)down, t); return; }
  if (_paused || _options) return;
  const int fret = [self fretForKey:ev.keyCode];
  if (fret >= 0) { if (down) _frets |= 1 << fret; else _frets &= ~(1 << fret); [self syncFrets:t]; return; }
  if (!down || _isReplay) return;
  if (ev.keyCode == k.strumUp || ev.keyCode == k.strumDown) [self enqueue:1 value:0 time:t];
  else if (ev.keyCode == k.starPower) [self enqueue:2 value:0 time:t];
  else if (ev.keyCode == k.pause) [self pause];
}
- (void)syncFrets:(double)t { if (_isReplay) return; [self enqueue:0 value:(_frets | _padFrets) time:t]; }
- (void)padState:(const gc::platform::PadState&)p prev:(const gc::platform::PadState&)prev {
  if (!_engine || _paused || _resuming || _finished) return;
  const auto& g = settings().pad;
  const double t = [self engineTime];
  auto down = [&](int b) { return b >= 0 && b < 16 && p.buttons[b]; };
  auto edge = [&](int b) { return down(b) && !prev.buttons[b]; };
  int mask = 0;
  for (int i = 0; i < 5; i++) if (down(g.frets[i])) mask |= 1 << i;
  if (mask != _padFrets) { _padFrets = mask; [self syncFrets:t]; }
  if (_isReplay) { if (edge(g.pause)) [self pause]; return; }
  if (edge(g.strumUp) || edge(g.strumDown)) [self enqueue:1 value:0 time:t];
  if (edge(g.starPower)) [self enqueue:2 value:0 time:t];
  if (edge(g.pause)) [self pause];
  if (g.whammyAxis >= 0 && g.whammyAxis < 4) _padWhammy = std::max(0.f, std::min(1.f, (p.axes[g.whammyAxis] + 1) / 2));
  if (g.tiltAxis >= 0 && g.tiltAxis < 4 && p.axes[g.tiltAxis] < -0.5f && prev.axes[g.tiltAxis] >= -0.5f) [self activateStarPower];
  if (p.hasMotion) {  // raise the neck past ~40 degrees to fire star power; re-arm once it comes back down
    if (p.tilt > 0.65f && _tiltArmed) { _tiltArmed = false; [self activateStarPower]; }
    else if (p.tilt < 0.35f) _tiltArmed = true;
  }
}
- (void)menuAction:(NSString*)action {
  if (_pausedByThisKey) { _pausedByThisKey = false; return; }
  if (!_paused) return;
  if (_resuming) return;
  if (_options) { [_options menuAction:action]; return; }
  if ([action isEqualToString:@"back"]) { [self resume]; return; }
  [_pauseMenu handle:action];
}

// ------------------------------------------------------------------ options overlay (Video tab first, applies live over the paused highway)
- (void)openOptions {
  if (_options || !_paused) return;
  _pauseOverlay.hidden = YES;
  _hud.hidden = YES;
  __weak GameplayScreen* weakSelf = self;
  _options = [[OptionsScreen alloc] initWithTab:@"video" overlay:YES];
  _options.onClose = ^{ [weakSelf closeOptions]; };
  _options.onChange = ^{ [weakSelf applyLiveSettings]; };
  [_options enter:_stage];
  [_stage relayout];
}
- (void)closeOptions {
  if (!_options) return;
  [_options exit];
  _options = nil;
  _pauseOverlay.hidden = NO;
  _hud.hidden = NO;
  [self applyLiveSettings];
  [_stage relayout];
}

// ------------------------------------------------------------------ pause
- (void)pause {
  if (_paused || _finished) return;
  _paused = true;
  _mixer->pause();
  _pauseOverlay = [[GCBox alloc] initWithFrame:NSZeroRect];
  _pauseOverlay.left = 0; _pauseOverlay.right = 0; _pauseOverlay.top = 0; _pauseOverlay.bottom = 0;
  _pauseOverlay.fill = GCColor(GC_BG, 0.55);
  [_stage addSubview:_pauseOverlay];
  GCBox* scrim = [[GCBox alloc] initWithFrame:NSZeroRect];
  scrim.left = 0; scrim.top = 0; scrim.bottom = 0; scrim.width = 760; scrim.fill = GCColor(GC_BG, 0.85);
  [_pauseOverlay addSubview:scrim];
  GCLabel* k = GCMakeLabel(@"THE STAGE CAN WAIT.", 14, NO, 400, GC_YELLOW); k.tracking = 0.18; k.left = 80; k.top = 110; [_pauseOverlay addSubview:k];
  GCLabel* t = GCMakeLabel(@"Paused.", 104, YES, 800, GC_INK); t.left = 80; t.top = 144; t.lineHeight = 104; [_pauseOverlay addSubview:t];
  const SongEntry* entry = Library::instance().byId(_songId);
  GCLabel* s = GCMakeLabel([NSString stringWithFormat:@"%s · %@ · %@", entry->meta.name.c_str(), [@(instrumentName(_instrument)) capitalizedString], [@(difficultyName(_difficulty)) capitalizedString]], 17, NO, 400, GC_MUTED); s.left = 80; s.top = 264; [_pauseOverlay addSubview:s];
  __weak GameplayScreen* weakSelf = self;
  _pauseMenu = [[GCMenuList alloc] initWithItems:@[@"Back to the riff", _practice ? @"Restart section" : @"Restart song", @"Options", @"Exit to song select"] dim:@[@NO, @NO, @NO, @YES] numbered:NO width:480 actions:@[
    ^{ [weakSelf resume]; },
    ^{ [weakSelf restartSong]; },
    ^{ [weakSelf openOptions]; },
    ^{ [GCApp.shared showSongSelect:@"quickplay"]; }]];
  _pauseMenu.onMove = ^{ audio::Sfx::instance().playMenuMove(); };
  _pauseMenu.view.left = 80; _pauseMenu.view.top = 356;
  [_pauseOverlay addSubview:_pauseMenu.view];
  GCBox* rule = GCRule(); rule.left = 80; rule.width = 480; rule.bottom = 130; [_pauseOverlay addSubview:rule];
  GCLabel* cd = GCMakeLabel(@"3 · 2 · 1", 48, YES, 700, GC_YELLOW); cd.left = 80; cd.bottom = 60; [_pauseOverlay addSubview:cd];
  GCLabel* cdt = GCMakeLabel(@"A beat to get ready.\nResume with a short countdown.", 15, NO, 400, GC_MUTED); cdt.left = 216; cdt.bottom = 62; cdt.width = 300; cdt.wraps = YES; cdt.lineHeight = 23; [_pauseOverlay addSubview:cdt];
  [_pauseMenu relayout];
}
- (void)restartSong {
  if (_practice) { [_pauseOverlay removeFromSuperview]; _pauseOverlay = nil; _paused = false; [self restartRange]; return; }
  GCApp* app = GCApp.shared;
  [app startSong:@(_songId.c_str()) instrument:@(instrumentName(_instrument)) difficulty:@(difficultyName(_difficulty)) mode:@(_mode.c_str()) practiceStart:0 practiceEnd:0 speed:1 loop:NO];
}
- (void)resume {
  if (!_paused || _resuming) return;
  [_pauseOverlay removeFromSuperview];
  _pauseOverlay = nil;
  _pauseMenu = nil;
  _resuming = true;
  // rewind a little and snap the resume point to the beat grid so the count-in lands on the bar
  double t = std::max(_startTime, _mixer->time() - 0.6);
  double beatLen = 0.5;
  {
    const auto& beats = _song->chart.beats;
    size_t lo = 0, hi = beats.size();
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (beats[mid].time <= t) lo = mid + 1; else hi = mid; }
    if (lo > 0 && lo <= beats.size()) {
      const size_t i = lo - 1;
      if (beats[i].time >= _startTime) t = beats[i].time;
      if (i + 1 < beats.size()) beatLen = beats[i + 1].time - beats[i].time;
    }
  }
  const double rate = _speed > 0 ? _speed : 1.0;
  const double beat = std::max(0.2, std::min(1.2, beatLen)) / rate;
  NSArray* steps = @[@"3", @"2", @"1"];
  for (NSUInteger i = 0; i < steps.count; i++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(i * beat * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ self->_countdown.text = steps[i]; self->_countdownDone = false; });
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(steps.count * beat * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    self->_countdown.text = @"";
    self->_countdownDone = true;
    self->_paused = false;
    self->_resuming = false;
    self->_mixer->play(t, self->_practice ? self->_speed : 1.0);
  });
}
@end
