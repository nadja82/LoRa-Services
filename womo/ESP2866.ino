/************************************************************
 * ESP8266 DHT -> HTTP API (für Raspberry Pi per curl)
 * - mDNS: http://envnode.local/
 * - Endpunkte:
 *   GET /          -> HTML Statusseite
 *   GET /api/now   -> JSON {"t":<°C>,"h":<%>,"age_ms":0}
 *   GET /metrics   -> Prometheus-Metriken
 ************************************************************/
#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <DHT.h>

const char* WIFI_SSID = "SSID";
const char* WIFI_PASS = "PWD";
const char* HOSTNAME  = "envnode";   // => envnode.local

// ---- DHT Sensor ----
#define DHTPIN  D5
#define DHTTYPE DHT22       // bei DHT11: DHT11
DHT dht(DHTPIN, DHTTYPE);

ESP8266WebServer server(80);

String htmlPage(float t, float h, const String& ip) {
  String st = isnan(t) ? "–" : String(t,1) + " °C";
  String sh = isnan(h) ? "–" : String(h,1) + " %";
  String s  =
    "<!doctype html><html><head><meta charset='utf-8'>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<title>ESP8266 Sensor</title>"
    "<style>body{font-family:system-ui;margin:24px}</style>"
    "</head><body>"
    "<h1>ESP8266 Sensor</h1>"
    "<p><b>IP:</b> " + ip + "</p>"
    "<p><b>Temperatur:</b> " + st + "<br>"
    "<b>Luftfeuchte:</b> " + sh + "</p>"
    "<p>API: <a href='/api/now'>/api/now</a> | <a href='/metrics'>/metrics</a></p>"
    "</body></html>";
  return s;
}

void handleNow() {
  float h = dht.readHumidity();
  float t = dht.readTemperature();
  if (isnan(h) || isnan(t)) {
    server.send(503, "application/json", "{\"error\":\"sensor_read_failed\"}");
    return;
  }
  String json = "{\"t\":" + String(t,2) + ",\"h\":" + String(h,2) + ",\"age_ms\":0}";
  server.send(200, "application/json", json);
}

void handleMetrics() {
  float h = dht.readHumidity();
  float t = dht.readTemperature();
  if (isnan(h) || isnan(t)) {
    server.send(503, "text/plain", "# sensor_read_failed 1\n");
    return;
  }
  String m = "";
  m += "# HELP env_temperature_celsius Temperatur in °C\n";
  m += "# TYPE env_temperature_celsius gauge\n";
  m += "env_temperature_celsius " + String(t,2) + "\n";
  m += "# HELP env_humidity_percent Luftfeuchte in %\n";
  m += "# TYPE env_humidity_percent gauge\n";
  m += "env_humidity_percent " + String(h,2) + "\n";
  server.send(200, "text/plain; version=0.0.4", m);
}

void handleRoot() {
  // Eine schnelle Messung für die Seite
  float h = dht.readHumidity();
  float t = dht.readTemperature();
  server.send(200, "text/html; charset=utf-8", htmlPage(t, h, WiFi.localIP().toString()));
}

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);

  Serial.begin(115200);
  delay(50);
  dht.begin();

  WiFi.mode(WIFI_STA);
  WiFi.hostname(HOSTNAME);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.printf("Verbinde mit %s ...\n", WIFI_SSID);
  while (WiFi.status() != WL_CONNECTED) { delay(400); Serial.print("."); }
  Serial.printf("\nVerbunden. IP: %s\n", WiFi.localIP().toString().c_str());

  server.on("/", handleRoot);
  server.on("/api/now", handleNow);
  server.on("/metrics", handleMetrics);
  server.begin();
  Serial.println("HTTP-Server auf Port 80 gestartet.");

  if (MDNS.begin(HOSTNAME)) {
    MDNS.addService("http", "tcp", 80);
    Serial.printf("mDNS aktiv: http://%s.local/\n", HOSTNAME);
  } else {
    Serial.println("mDNS Start fehlgeschlagen.");
  }
}

void loop() {
  server.handleClient();
  MDNS.update();
}
