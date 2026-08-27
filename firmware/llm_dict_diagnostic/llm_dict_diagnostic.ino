#include <PDM.h>
#include <math.h>

namespace {

constexpr uint32_t kSerialBaud = 115200;
constexpr uint32_t kSerialWaitMs = 2500;
constexpr uint32_t kReportIntervalMs = 250;
constexpr uint32_t kButtonStateReportIntervalMs = 1000;
constexpr uint32_t kDebounceMs = 30;
constexpr int kSampleRate = 16000;
constexpr int kChannels = 1;
constexpr uint8_t kButtonPin = D10;

int16_t sampleBuffer[256];

volatile uint64_t audioSumSquares = 0;
volatile uint32_t audioSampleCount = 0;
volatile uint16_t audioPeak = 0;

bool lastRawButtonState = HIGH;
bool stableButtonState = HIGH;
uint32_t lastRawButtonChangeMs = 0;
uint32_t lastAudioReportMs = 0;
uint32_t lastButtonStateReportMs = 0;

void onPDMData() {
  const int bytesAvailable = PDM.available();
  if (bytesAvailable <= 0) {
    return;
  }

  const int bytesToRead =
      min(bytesAvailable, static_cast<int>(sizeof(sampleBuffer)));
  const int bytesRead = PDM.read(sampleBuffer, bytesToRead);
  const int samplesRead = bytesRead / static_cast<int>(sizeof(int16_t));

  uint64_t blockSumSquares = 0;
  uint16_t blockPeak = 0;

  for (int index = 0; index < samplesRead; ++index) {
    const int32_t sample = sampleBuffer[index];
    const uint16_t magnitude =
        static_cast<uint16_t>(sample < 0 ? -sample : sample);

    blockSumSquares += static_cast<uint64_t>(sample * sample);
    if (magnitude > blockPeak) {
      blockPeak = magnitude;
    }
  }

  audioSumSquares += blockSumSquares;
  audioSampleCount += static_cast<uint32_t>(samplesRead);
  if (blockPeak > audioPeak) {
    audioPeak = blockPeak;
  }
}

void reportButtonEvent(bool pressed) {
  digitalWrite(LED_BUILTIN, pressed ? LED_STATE_ON : !LED_STATE_ON);
  Serial.print("BUTTON:");
  Serial.println(pressed ? "PRESSED" : "RELEASED");
}

void updateButton(uint32_t nowMs) {
  const bool rawState = digitalRead(kButtonPin);

  if (rawState != lastRawButtonState) {
    lastRawButtonState = rawState;
    lastRawButtonChangeMs = nowMs;
  }

  if (rawState != stableButtonState &&
      nowMs - lastRawButtonChangeMs >= kDebounceMs) {
    stableButtonState = rawState;
    reportButtonEvent(stableButtonState == LOW);
  }

  if (nowMs - lastButtonStateReportMs >= kButtonStateReportIntervalMs) {
    lastButtonStateReportMs = nowMs;
    Serial.print("BUTTON:STATE=");
    Serial.print(stableButtonState == LOW ? "PRESSED" : "RELEASED");
    Serial.print(",RAW=");
    Serial.println(rawState == LOW ? "LOW" : "HIGH");
  }
}

void reportAudioLevel(uint32_t nowMs) {
  if (nowMs - lastAudioReportMs < kReportIntervalMs) {
    return;
  }
  lastAudioReportMs = nowMs;

  noInterrupts();
  const uint64_t sumSquares = audioSumSquares;
  const uint32_t sampleCount = audioSampleCount;
  const uint16_t peak = audioPeak;
  audioSumSquares = 0;
  audioSampleCount = 0;
  audioPeak = 0;
  interrupts();

  if (sampleCount == 0) {
    Serial.println("AUDIO:NO_SAMPLES");
    return;
  }

  const double rms = sqrt(static_cast<double>(sumSquares) / sampleCount);
  const double dbfs = rms > 0.0 ? 20.0 * log10(rms / 32768.0) : -96.0;

  Serial.print("AUDIO:rms=");
  Serial.print(rms, 1);
  Serial.print(",peak=");
  Serial.print(peak);
  Serial.print(",dbfs=");
  Serial.print(dbfs, 1);
  Serial.print(",samples=");
  Serial.println(sampleCount);
}

}  // namespace

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, !LED_STATE_ON);

  pinMode(kButtonPin, INPUT_PULLUP);
  lastRawButtonState = digitalRead(kButtonPin);
  stableButtonState = lastRawButtonState;
  lastRawButtonChangeMs = millis();

  Serial.begin(kSerialBaud);
  const uint32_t serialWaitStartedMs = millis();
  while (!Serial && millis() - serialWaitStartedMs < kSerialWaitMs) {
    delay(10);
  }

  Serial.println();
  Serial.println("BOOT:LLM_DICT_DIAGNOSTIC_V1");
  Serial.println("BOARD:XIAO_NRF52840_SENSE_PLUS");
  Serial.println("BUTTON:D10_TO_GND,ACTIVE_LOW,INPUT_PULLUP");
  Serial.print("BUTTON:INITIAL=");
  Serial.print(stableButtonState == LOW ? "PRESSED" : "RELEASED");
  Serial.print(",RAW=");
  Serial.println(lastRawButtonState == LOW ? "LOW" : "HIGH");
  Serial.println("AUDIO:PDM,MONO,16000_HZ,16_BIT");

  PDM.onReceive(onPDMData);
  PDM.setBufferSize(sizeof(sampleBuffer));
  PDM.setGain(30);

  if (!PDM.begin(kChannels, kSampleRate)) {
    Serial.println("FATAL:PDM_START_FAILED");
    while (true) {
      digitalWrite(LED_BUILTIN, LED_STATE_ON);
      delay(100);
      digitalWrite(LED_BUILTIN, !LED_STATE_ON);
      delay(100);
    }
  }

  Serial.println("READY");
}

void loop() {
  const uint32_t nowMs = millis();
  updateButton(nowMs);
  reportAudioLevel(nowMs);
  delay(1);
}
