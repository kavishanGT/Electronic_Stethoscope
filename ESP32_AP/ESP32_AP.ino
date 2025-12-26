#include <WiFi.h>
#include <WiFiUdp.h>

// ============ AP CONFIG ============
const char* AP_SSID = "HeartbeatESP";
const char* AP_PASS = "12345678";

// ============ UDP CONFIG ===========
IPAddress matlabIP(192,168,4,2);   // PC IP after connecting to AP
const uint16_t UDP_PORT = 4210;
WiFiUDP udp;

// ============ ADC CONFIG ===========
#define ADC_PIN 3
#define FS 8000
#define PACKET_SAMPLES 256

uint16_t buffer[PACKET_SAMPLES];

void setup() {
  Serial.begin(115200);
  delay(1000);

  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  // 🔴 AP MODE
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);

  Serial.print("ESP32 AP IP: ");
  Serial.println(WiFi.softAPIP());   // 192.168.4.1

  udp.begin(UDP_PORT);
}

void loop() {
  static uint32_t lastMicros = micros();
  static uint16_t idx = 0;
  const uint32_t Ts = 1000000UL / FS;

  if ((uint32_t)(micros() - lastMicros) >= Ts) {
    lastMicros += Ts;
    buffer[idx++] = analogRead(ADC_PIN);

    if (idx >= PACKET_SAMPLES) {
      udp.beginPacket(matlabIP, UDP_PORT);
      udp.write((uint8_t*)buffer, sizeof(buffer));
      udp.endPacket();
      idx = 0;
    }
  }
}
