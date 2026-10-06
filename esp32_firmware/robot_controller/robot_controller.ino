/*
 * Ramp bot + 4-servo arm - ESP32 + L298N + 4 DC motors + 4 servos
 * Bluetooth control (classic SPP) + WiFi Web Controller
 *
 * Pair the phone with "RampBot" in Android Bluetooth settings, then connect
 * from the app. OR connect to the WiFi AP "RampBot-WiFi" and open 192.168.4.1
 *
 * ---------------- PROTOCOL ----------------
 * Drive (single characters, no terminator needed):
 *   F forward   B backward   L spin left   R spin right
 *   G fwd-left  I fwd-right  H back-left   J back-right
 *   S stop      0..9 speed   q full speed
 *
 * Arm / joystick (text lines ending in newline, '\r' or '#'):
 *   a<0-180>   servo 1 (base)       e.g.  a90
 *   b<0-180>   servo 2 (shoulder)
 *   c<0-180>   servo 3 (elbow)
 *   d<0-180>   servo 4 (gripper)
 *   j<x>,<y>   joystick, each -100..100 (x = turn, y = throttle)   e.g.  j-40,100
 *   P          arm back to home pose (single char)
 *
 * CHANGES from previous version:
 *   - Gripper: 5x faster (SERVO_STEP_DEG 2->10, SERVO_UPDATE_MS 15->8)
 *   - Motor torque: PWM freq 2000->500 Hz for more torque through L298N
 *   - Motor min PWM raised: MIN_PWM 90->120 to overcome static friction
 *   - Kick pulse stronger: KICK_MS 120->200 ms for heavy loads
 *   - Command timeout: 200->500 ms to prevent premature stops
 *   - Added WiFi AP + web controller on http://192.168.4.1
 *
 * Servo power: use a separate 5-6V supply (BEC/buck) for the servos and
 * join its GND with the ESP32 and L298N grounds. Do NOT power them from the ESP32.
 */

#include "BluetoothSerial.h"
#include <WiFi.h>
#include <WebServer.h>

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled! Use an ESP32 Dev Module board.
#endif

BluetoothSerial SerialBT;
WebServer server(80);

// WiFi AP credentials
const char* AP_SSID = "RampBot-WiFi";
const char* AP_PASS = "rampbot123";   // min 8 chars

// ---------- Drive pins ----------
const int ENA = 14, IN1 = 26, IN2 = 27;   // Left motors
const int ENB = 32, IN3 = 25, IN4 = 33;   // Right motors

// ---------- Servo pins ----------
const int NUM_SERVOS = 4;
//                                 a   b   c   d
// NOTE: GPIO 34/35 are input-only on ESP32 and cannot drive servos.
// GPIO 12 is a boot-strapping pin: if the board fails to boot with a servo
// connected, unplug the servo signal wire while uploading/resetting, or move this to 18.
const int SERVO_PIN[NUM_SERVOS] = {12, 13, 18, 19};

// Per-servo safe limits (degrees) - narrow these to protect your arm/gripper
const int SERVO_MIN[NUM_SERVOS]  = {0,   0,   0,   0};
const int SERVO_MAX[NUM_SERVOS]  = {180, 180, 180, 180};
const int SERVO_HOME[NUM_SERVOS] = {90,  90,  90,  90};

const int SERVO_MIN_US = 500;             // pulse width at 0 deg   (use 1000 if servo buzzes at the ends)
const int SERVO_MAX_US = 2500;            // pulse width at 180 deg (use 2000 likewise)

// *** GRIPPER SPEED FIX: increased step from 2 to 10 deg, decreased interval from 15 to 8 ms ***
const int SERVO_STEP_DEG = 10;            // degrees per update  -> MUCH faster gripper
const unsigned long SERVO_UPDATE_MS = 8;  // ms between servo steps -> smoother & faster

// ---------- Motor PWM ----------
// *** TORQUE FIX: lowered PWM freq from 2000 to 500 Hz ***
// L298N has slow switching transistors; lower freq = less switching loss = more torque
const int PWM_FREQ = 500;
const int PWM_RES  = 8;                   // 0..255

// ---------- Drive tuning ----------
// *** TORQUE FIX: raised MIN_PWM from 90 to 120 to overcome static friction with heavy loads ***
const int  MIN_PWM       = 120;
const int  PIVOT_MIN_PWM = 210;
const int  KICK_PWM      = 255;
// *** TORQUE FIX: longer kick pulse from 120 to 200 ms for heavy box pickup ***
const unsigned long KICK_MS = 200;
const float TURN_GAIN    = 1.6;
const int  DIAG_TURN     = 60;
const int  JOY_DEADZONE  = 8;
const int  STEER_DIR     = -1;            // -1 = flipped steering; set to 1 to flip back

int maxPwm = 255;

bool leftMoving = false, rightMoving = false;
int lastSignL = 0, lastSignR = 0;
bool wasConnected = false;

int servoCur[NUM_SERVOS];
int servoTarget[NUM_SERVOS];
unsigned long lastServoUpdate = 0;

// *** ROVER FIX: increased command timeout from 200 to 500 ms ***
// 200ms was too aggressive - BT latency could cause premature stops
unsigned long lastCommandTime = 0;
const unsigned long COMMAND_TIMEOUT_MS = 500;

// Line parser state
String lineBuf = "";
bool lineMode = false;

// =====================================================================
//  PWM helpers
// =====================================================================
// Core 2.x channel map: 0,1 = motors, 2..5 = servos (motors and servos land on different timers, no clash)
void pwmSetup() {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(ENA, PWM_FREQ, PWM_RES);
  ledcAttach(ENB, PWM_FREQ, PWM_RES);
  for (int i = 0; i < NUM_SERVOS; i++) ledcAttach(SERVO_PIN[i], 50, 16);
#else
  ledcSetup(0, PWM_FREQ, PWM_RES);
  ledcSetup(1, PWM_FREQ, PWM_RES);
  ledcAttachPin(ENA, 0);
  ledcAttachPin(ENB, 1);
  for (int i = 0; i < NUM_SERVOS; i++) {
    ledcSetup(2 + i, 50, 16);
    ledcAttachPin(SERVO_PIN[i], 2 + i);
  }
#endif
}

void pwmWrite(bool left, int duty) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(left ? ENA : ENB, duty);
#else
  ledcWrite(left ? 0 : 1, duty);
#endif
}

void servoWrite(int i, int angle) {
  int us = map(angle, 0, 180, SERVO_MIN_US, SERVO_MAX_US);
  uint32_t duty = (uint32_t)us * 65535UL / 20000UL;   // 20 ms period, 16-bit
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(SERVO_PIN[i], duty);
#else
  ledcWrite(2 + i, duty);
#endif
}

// =====================================================================
//  Motors
// =====================================================================
void setSide(bool left, int v, int minPwm = MIN_PWM) {
  int a = left ? IN1 : IN3;
  int b = left ? IN2 : IN4;
  bool &moving = left ? leftMoving : rightMoving;
  int &lastSign = left ? lastSignL : lastSignR;

  if (v == 0) {
    digitalWrite(a, LOW); digitalWrite(b, LOW);
    pwmWrite(left, 0);
    moving = false;
    lastSign = 0;
    return;
  }

  int sign = v > 0 ? 1 : -1;
  digitalWrite(a, sign > 0 ? HIGH : LOW);
  digitalWrite(b, sign > 0 ? LOW : HIGH);

  int duty = map(abs(v), 1, 255, minPwm, 255);

  if (!moving || sign != lastSign) {      // kick on start and direction change
    pwmWrite(left, KICK_PWM);
    delay(KICK_MS);
    moving = true;
    lastSign = sign;
  }
  pwmWrite(left, duty);
}

void stopMotors() {
  setSide(true, 0);
  setSide(false, 0);
}

// x = turn (-100..100, + = right), y = throttle (-100..100)
void drive(int x, int y) {
  float xs = constrain(x * TURN_GAIN * STEER_DIR, -100, 100);

  if (y == 0 && xs != 0) {                // spin in place
    int v = (int)(fabs(xs) * 255 / 100.0);
    setSide(true,   xs > 0 ?  v : -v, PIVOT_MIN_PWM);
    setSide(false,  xs > 0 ? -v :  v, PIVOT_MIN_PWM);
    return;
  }

  float l = y + xs;
  float r = y - xs;
  float m = max(fabs(l), fabs(r));
  if (m > 100) { l = l * 100 / m; r = r * 100 / m; }

  int minL = (l * y < 0) ? PIVOT_MIN_PWM : MIN_PWM;
  int minR = (r * y < 0) ? PIVOT_MIN_PWM : MIN_PWM;

  setSide(true,  (int)(l * maxPwm / 100.0), minL);
  setSide(false, (int)(r * maxPwm / 100.0), minR);
}

// =====================================================================
//  Servos (smooth, non-blocking)
// =====================================================================
void setServoTarget(int i, int angle) {
  servoTarget[i] = constrain(angle, SERVO_MIN[i], SERVO_MAX[i]);
}

void armHome() {
  for (int i = 0; i < NUM_SERVOS; i++) setServoTarget(i, SERVO_HOME[i]);
}

void updateServos() {
  if (millis() - lastServoUpdate < SERVO_UPDATE_MS) return;
  lastServoUpdate = millis();
  for (int i = 0; i < NUM_SERVOS; i++) {
    if (servoCur[i] == servoTarget[i]) continue;
    int d = servoTarget[i] - servoCur[i];
    servoCur[i] += (abs(d) <= SERVO_STEP_DEG) ? d : (d > 0 ? SERVO_STEP_DEG : -SERVO_STEP_DEG);
    servoWrite(i, servoCur[i]);
  }
}

// =====================================================================
//  Command parsing
// =====================================================================
void handleCommand(char c) {              // single-character commands
  switch (c) {
    case 'F': drive(0, 100);               break;
    case 'B': drive(0, -100);              break;
    case 'L': drive(-100, 0);              break;
    case 'R': drive(100, 0);               break;
    case 'G': drive(-DIAG_TURN, 100);      break;
    case 'I': drive(DIAG_TURN, 100);       break;
    case 'H': drive(-DIAG_TURN, -100);     break;
    case 'J': drive(DIAG_TURN, -100);      break;
    case 'S': case 'D': stopMotors();      break;
    case 'P': armHome();                   break;
    case 'q': maxPwm = 255;                break;
    default:
      if (c >= '0' && c <= '9') maxPwm = 100 + (c - '0') * 17;   // 100..253
      break;
  }
}

void handleLine(const String &s) {        // "a90", "j-40,100"
  if (s.length() < 2) return;
  char t = s[0];

  if (t >= 'a' && t <= 'd') {
    setServoTarget(t - 'a', s.substring(1).toInt());
  } else if (t == 'j') {
    int comma = s.indexOf(',');
    if (comma < 0) return;
    int x = constrain(s.substring(1, comma).toInt(), -100, 100);
    int y = constrain(s.substring(comma + 1).toInt(), -100, 100);
    if (abs(x) < JOY_DEADZONE) x = 0;
    if (abs(y) < JOY_DEADZONE) y = 0;
    if (x == 0 && y == 0) stopMotors();
    else drive(x, y);
  }
}

void onChar(char c) {
  lastCommandTime = millis();          // reset failsafe timer on every byte
  if (lineMode) {
    if (c == '\n' || c == '\r' || c == '#') {
      handleLine(lineBuf);
      lineBuf = "";
      lineMode = false;
    } else if (lineBuf.length() < 24) {
      lineBuf += c;
    } else {                              // garbage - reset
      lineBuf = "";
      lineMode = false;
    }
    return;
  }

  if ((c >= 'a' && c <= 'd') || c == 'j') {   // start of a line command
    lineMode = true;
    lineBuf = String(c);
    return;
  }
  if (c == '\n' || c == '\r' || c == '#' || c == ' ') return;
  handleCommand(c);
}

// =====================================================================
//  Web controller page (served from ESP32 flash)
// =====================================================================
const char WEB_PAGE[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<title>RampBot Controller</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent;touch-action:manipulation}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#0A0E21;color:#fff;height:100vh;overflow:hidden;display:flex;flex-direction:column}
.header{display:flex;align-items:center;justify-content:space-between;padding:8px 16px;background:linear-gradient(135deg,#0f1629,#1a2344);border-bottom:1px solid #1c2b4c}
.header h1{font-size:16px;font-weight:800;background:linear-gradient(135deg,#00e5ff,#76ff03);-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:1px}
.status{font-size:11px;padding:4px 10px;border-radius:20px;font-weight:700}
.status.ok{background:rgba(118,255,3,.15);color:#76ff03;border:1px solid rgba(118,255,3,.3)}
.main{flex:1;display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;padding:10px;overflow:hidden}
.panel{background:#10172d;border:1px solid #1c2b4c;border-radius:16px;padding:10px;display:flex;flex-direction:column;align-items:center;justify-content:space-evenly;overflow:hidden}
.panel-title{font-size:10px;font-weight:800;letter-spacing:1.5px;color:rgba(255,255,255,.5);text-transform:uppercase;margin-bottom:4px}
.dpad{position:relative;width:160px;height:160px}
.dpad-btn{position:absolute;width:44px;height:44px;border-radius:10px;border:1px solid rgba(0,229,255,.25);background:rgba(0,229,255,.08);display:flex;align-items:center;justify-content:center;cursor:pointer;transition:all .15s;font-size:18px;color:#00e5ff;user-select:none}
.dpad-btn:active,.dpad-btn.active{background:rgba(0,229,255,.35);border-color:#00e5ff;box-shadow:0 0 15px rgba(0,229,255,.4);transform:scale(1.05)}
.dpad-btn.stop{background:rgba(255,64,129,.12);border-color:rgba(255,64,129,.3);color:#ff4081}
.dpad-btn.stop:active{background:rgba(255,64,129,.4);border-color:#ff4081}
.dpad-btn.diag{width:36px;height:36px;font-size:14px;border-radius:8px}
.speed-bar{width:100%;margin-top:6px}
.speed-bar label{font-size:9px;color:rgba(255,255,255,.5);font-weight:700;letter-spacing:1px}
.speed-bar input[type=range]{width:100%;height:6px;-webkit-appearance:none;background:#1b2745;border-radius:3px;outline:none;margin-top:4px}
.speed-bar input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;background:#00e5ff;border-radius:50%;cursor:pointer;box-shadow:0 0 8px rgba(0,229,255,.5)}
.servo-group{display:flex;gap:6px;flex-wrap:wrap;justify-content:center;width:100%}
.servo-card{background:#141d35;border:1px solid #213054;border-radius:10px;padding:8px;text-align:center;flex:1;min-width:70px;max-width:100px}
.servo-card .name{font-size:9px;font-weight:800;letter-spacing:1px;margin-bottom:4px}
.servo-card .value{font-size:16px;font-weight:900;font-family:monospace}
.servo-card input[type=range]{width:100%;height:4px;-webkit-appearance:none;background:#1b2745;border-radius:2px;margin-top:4px}
.servo-card input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:12px;height:12px;border-radius:50%;cursor:pointer;box-shadow:0 0 6px}
.s0 .name,.s0 .value{color:#00e5ff}.s0 input::-webkit-slider-thumb{background:#00e5ff}
.s1 .name,.s1 .value{color:#76ff03}.s1 input::-webkit-slider-thumb{background:#76ff03}
.s2 .name,.s2 .value{color:#ffab40}.s2 input::-webkit-slider-thumb{background:#ffab40}
.s3 .name,.s3 .value{color:#ff4081}.s3 input::-webkit-slider-thumb{background:#ff4081}
.grip-btns{display:flex;gap:6px;margin-top:6px}
.grip-btn{padding:6px 14px;border-radius:8px;font-size:10px;font-weight:800;letter-spacing:.5px;cursor:pointer;border:1px solid;transition:all .15s;user-select:none}
.grip-btn.open{background:rgba(118,255,3,.1);border-color:rgba(118,255,3,.3);color:#76ff03}
.grip-btn.open:active{background:rgba(118,255,3,.35)}
.grip-btn.close{background:rgba(255,64,129,.1);border-color:rgba(255,64,129,.3);color:#ff4081}
.grip-btn.close:active{background:rgba(255,64,129,.35)}
.home-btn{padding:6px 16px;border-radius:8px;font-size:11px;font-weight:800;letter-spacing:.8px;cursor:pointer;border:none;background:linear-gradient(135deg,#ff4081,#e040fb);color:#fff;box-shadow:0 0 12px rgba(255,64,129,.3);transition:all .15s;margin-top:4px}
.home-btn:active{transform:scale(.95);box-shadow:0 0 20px rgba(255,64,129,.5)}
.cmd-badge{font-size:10px;font-family:monospace;padding:3px 8px;background:rgba(0,229,255,.1);border:1px solid rgba(0,229,255,.25);border-radius:6px;color:#00e5ff;font-weight:700}
@media(max-width:768px){.main{grid-template-columns:1fr;grid-template-rows:auto auto auto}}
</style>
</head>
<body>
<div class="header">
  <h1>&#x1F916; RAMPBOT CONTROLLER</h1>
  <span class="status ok">&#x26A1; WiFi Connected</span>
  <span class="cmd-badge" id="cmdBadge">CMD: --</span>
</div>
<div class="main">
  <!-- DRIVE PANEL -->
  <div class="panel">
    <div class="panel-title">DRIVE MOVEMENT</div>
    <div class="dpad">
      <div class="dpad-btn" style="top:0;left:50px" data-cmd="F">&#x25B2;</div>
      <div class="dpad-btn" style="bottom:0;left:50px" data-cmd="B">&#x25BC;</div>
      <div class="dpad-btn" style="left:0;top:58px" data-cmd="L">&#x25C0;</div>
      <div class="dpad-btn" style="right:0;top:58px" data-cmd="R">&#x25B6;</div>
      <div class="dpad-btn diag" style="top:8px;left:8px" data-cmd="G">&#x2196;</div>
      <div class="dpad-btn diag" style="top:8px;right:8px" data-cmd="I">&#x2197;</div>
      <div class="dpad-btn diag" style="bottom:8px;left:8px" data-cmd="H">&#x2199;</div>
      <div class="dpad-btn diag" style="bottom:8px;right:8px" data-cmd="J">&#x2198;</div>
      <div class="dpad-btn stop" style="left:50%;top:50%;transform:translate(-50%,-50%);width:42px;height:42px" data-cmd="S">&#x25A0;</div>
    </div>
    <div class="speed-bar">
      <label>SPEED: <span id="speedVal">10</span></label>
      <input type="range" min="0" max="10" value="10" id="speedSlider">
    </div>
  </div>

  <!-- ARM SERVOS PANEL -->
  <div class="panel">
    <div class="panel-title">ARM SERVOS</div>
    <div class="servo-group">
      <div class="servo-card s0"><div class="name">BASE (a)</div><div class="value" id="sv0">90&deg;</div><input type="range" min="0" max="180" value="90" data-servo="0"></div>
      <div class="servo-card s1"><div class="name">SHOULDER (b)</div><div class="value" id="sv1">90&deg;</div><input type="range" min="0" max="180" value="90" data-servo="1"></div>
      <div class="servo-card s2"><div class="name">ELBOW (c)</div><div class="value" id="sv2">90&deg;</div><input type="range" min="0" max="180" value="90" data-servo="2"></div>
      <div class="servo-card s3"><div class="name">GRIPPER (d)</div><div class="value" id="sv3">90&deg;</div><input type="range" min="0" max="180" value="90" data-servo="3"></div>
    </div>
    <div class="grip-btns">
      <div class="grip-btn open" id="gripOpen">&#x270B; OPEN</div>
      <div class="grip-btn close" id="gripClose">&#x270A; CLOSE</div>
    </div>
    <button class="home-btn" id="homeBtn">&#x1F3E0; HOME (90&deg;)</button>
  </div>

  <!-- STATUS PANEL -->
  <div class="panel">
    <div class="panel-title">STATUS</div>
    <div style="text-align:center">
      <div style="font-size:11px;color:rgba(255,255,255,.5);margin-bottom:6px">Servo Positions</div>
      <div id="statusText" style="font-family:monospace;font-size:12px;color:#76ff03;line-height:1.8">
        Base: 90&deg;<br>Shoulder: 90&deg;<br>Elbow: 90&deg;<br>Gripper: 90&deg;
      </div>
    </div>
    <div style="text-align:center;margin-top:8px">
      <div style="font-size:9px;color:rgba(255,255,255,.4);letter-spacing:1px">FIRMWARE INFO</div>
      <div style="font-size:10px;color:#ffab40;margin-top:4px">PWM: 500Hz &bull; Servo Step: 10&deg;/8ms</div>
      <div style="font-size:10px;color:#00e5ff;margin-top:2px">Torque Mode: HIGH</div>
    </div>
  </div>
</div>

<script>
const cmdBadge=document.getElementById('cmdBadge');
const speedSlider=document.getElementById('speedSlider');
const speedVal=document.getElementById('speedVal');
const servos=[0,1,2,3];
const servoLabels=['Base','Shoulder','Elbow','Gripper'];
const servoVals=servos.map(i=>document.getElementById('sv'+i));
const statusText=document.getElementById('statusText');
let angles=[90,90,90,90];

function send(path){
  fetch(path).catch(()=>{});
  cmdBadge.textContent='CMD: '+path.split('/').pop();
}

// D-Pad
document.querySelectorAll('.dpad-btn').forEach(btn=>{
  const cmd=btn.dataset.cmd;
  const start=()=>{btn.classList.add('active');send('/cmd?c='+cmd)};
  const stop=()=>{btn.classList.remove('active');send('/cmd?c=S')};
  btn.addEventListener('mousedown',start);
  btn.addEventListener('mouseup',stop);
  btn.addEventListener('mouseleave',stop);
  btn.addEventListener('touchstart',e=>{e.preventDefault();start()});
  btn.addEventListener('touchend',e=>{e.preventDefault();stop()});
});

// Speed
speedSlider.addEventListener('input',()=>{
  const v=speedSlider.value;
  speedVal.textContent=v;
  send('/cmd?c='+(v>=10?'q':v));
});

// Servo sliders
document.querySelectorAll('[data-servo]').forEach(sl=>{
  const i=parseInt(sl.dataset.servo);
  sl.addEventListener('input',()=>{
    const v=sl.value;
    angles[i]=parseInt(v);
    servoVals[i].innerHTML=v+'&deg;';
    send('/servo?i='+i+'&a='+v);
    updateStatus();
  });
});

// Gripper open/close
document.getElementById('gripOpen').addEventListener('click',()=>{
  const sl=document.querySelector('[data-servo="3"]');
  sl.value=30;angles[3]=30;servoVals[3].innerHTML='30&deg;';
  send('/servo?i=3&a=30');updateStatus();
});
document.getElementById('gripClose').addEventListener('click',()=>{
  const sl=document.querySelector('[data-servo="3"]');
  sl.value=150;angles[3]=150;servoVals[3].innerHTML='150&deg;';
  send('/servo?i=3&a=150');updateStatus();
});

// Home
document.getElementById('homeBtn').addEventListener('click',()=>{
  send('/cmd?c=P');
  servos.forEach(i=>{
    angles[i]=90;
    servoVals[i].innerHTML='90&deg;';
    document.querySelector('[data-servo="'+i+'"]').value=90;
  });
  updateStatus();
});

function updateStatus(){
  statusText.innerHTML=servoLabels.map((l,i)=>l+': '+angles[i]+'&deg;').join('<br>');
}
</script>
</body>
</html>
)rawliteral";

// =====================================================================
//  Web server handlers
// =====================================================================
void handleRoot() {
  server.send(200, "text/html", WEB_PAGE);
}

void handleCmd() {
  if (server.hasArg("c")) {
    String c = server.arg("c");
    if (c.length() > 0) {
      onChar(c[0]);
    }
  }
  server.send(200, "text/plain", "OK");
}

void handleServo() {
  if (server.hasArg("i") && server.hasArg("a")) {
    int i = server.arg("i").toInt();
    int a = server.arg("a").toInt();
    if (i >= 0 && i < NUM_SERVOS) {
      setServoTarget(i, a);
    }
  }
  server.send(200, "text/plain", "OK");
}

// =====================================================================
//  Arduino
// =====================================================================
void setup() {
  Serial.begin(115200);
  pinMode(IN1, OUTPUT); pinMode(IN2, OUTPUT);
  pinMode(IN3, OUTPUT); pinMode(IN4, OUTPUT);
  pwmSetup();
  stopMotors();

  for (int i = 0; i < NUM_SERVOS; i++) {
    servoCur[i] = servoTarget[i] = SERVO_HOME[i];
    servoWrite(i, servoCur[i]);
  }

  // Start Bluetooth
  SerialBT.begin("RampBot");
  Serial.println("Bluetooth started. Pair with 'RampBot'.");

  // Start WiFi Access Point + Web Server
  WiFi.softAP(AP_SSID, AP_PASS);
  Serial.print("WiFi AP started. Connect to '");
  Serial.print(AP_SSID);
  Serial.print("' with password '");
  Serial.print(AP_PASS);
  Serial.println("'");
  Serial.print("Web controller: http://");
  Serial.println(WiFi.softAPIP());

  server.on("/", handleRoot);
  server.on("/cmd", handleCmd);
  server.on("/servo", handleServo);
  server.begin();
  Serial.println("Web server started on port 80");
}

void loop() {
  // Handle web requests
  server.handleClient();

  // Failsafe: stop the wheels if the phone disconnects
  bool connected = SerialBT.hasClient();
  if (wasConnected && !connected) {
    stopMotors();
    lineMode = false; lineBuf = "";
    Serial.println("Disconnected - wheels stopped");
  }
  wasConnected = connected;

  while (SerialBT.available()) onChar((char)SerialBT.read());
  while (Serial.available())   onChar((char)Serial.read());   // bench testing over USB

  // Failsafe: stop wheels if no command received within timeout
  if ((leftMoving || rightMoving) &&
      millis() - lastCommandTime > COMMAND_TIMEOUT_MS) {
    stopMotors();
    Serial.println("Command timeout - wheels stopped");
  }

  updateServos();
}
