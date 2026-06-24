// =============================================================================
//  BÁO CÁO — Cổng IoT ảo giám sát nước & cảnh báo sớm ngập lụt
//  Biên dịch:  typst compile main.typ
//
//  ẢNH CHỤP MÀN HÌNH: các hình S1..S10 hiện là ảnh placeholder trong images/.
//  Chỉ cần GHI ĐÈ đúng tên file (vd images/s3-grafana-level.png) bằng ảnh chụp
//  thật của bạn rồi biên dịch lại — không cần sửa file .typ này.
//  Danh sách cần chụp xem cuối file (phần ghi chú) hoặc bảng trong Chương 8–9.
// =============================================================================

#import "@preview/ilm:2.1.1": *

#set text(lang: "vi", font: ("Times New Roman", "Linux Libertine", "Libertinus Serif"))

#show: ilm.with(
  title: [Virtual Smart Water & Flood Early-Warning Gateway],
  authors: ("Dương Hữu Huynh — 20251197M", "Nông Đức Huy — MSSV", "Bùi Phạm Sơn Hà — MSSV"),
  date: datetime(year: 2026, month: 6, day: 24),
  chapter-pagebreak: false,
  raw-text: (font: ("Menlo", "DejaVu Sans Mono"), size: 9pt),
  abstract: [
  ],
  table-of-contents: outline(title: [Mục lục], depth: 2, indent: auto),
  figure-index: (enabled: true, title: "Danh mục hình"),
  table-index: (enabled: true, title: "Danh mục bảng"),
)

// ---- helper hiển thị sơ đồ & ảnh chụp -------------------------------------
#let dia(file, caption, width: 100%) = figure(
  image("images/" + file, width: width),
  caption: caption,
)
#let shot(file, caption, width: 92%) = figure(
  image("images/" + file, width: width),
  caption: caption,
)

// =============================================================================
= Giới thiệu
// =============================================================================

== Bối cảnh và động lực

Ngập lụt đô thị và lũ trên sông gây thiệt hại lớn về người và tài sản. Trong các
tình huống này, thời gian là yếu tố sống còn: cảnh báo sớm dù chỉ vài phút cũng đủ
để vận hành bơm tiêu úng, mở cửa xả, hú còi sơ tán và giảm đáng kể thiệt hại. Một hệ
thống quan trắc hiện đại thường đặt cảm biến tại nhiều trạm dọc sông hoặc kênh tiêu để
theo dõi mực nước, lưu lượng và lượng mưa theo thời gian thực.

Điểm mấu chốt là khả năng phản ứng tại chỗ: một gateway đặt tại biên (edge) có
thể phát hiện mực nước vượt ngưỡng và lập tức kích hoạt actuator mà không phụ
thuộc vào đường truyền lên server. Song song đó, dữ liệu vẫn được đẩy lên server để
trung tâm điều khiển theo dõi toàn lưu vực và ra lệnh từ xa khi cần.

== Mục tiêu

Mini-project triển khai toàn bộ hệ thống ở mức phần mềm — mọi thiết bị vật lý được giả
lập bằng Python trong container Docker — với các mục tiêu:

- Lập trình nhiều virtual sensor mô phỏng các trạm quan trắc khác nhau và một
  edge gateway nhận telemetry MQTT từ nhiều trạm.
- Thiết kế topic hierarchy và message format cho quan trắc nước; chuẩn hóa dữ liệu
  (mực nước, lưu lượng, lượng mưa, độ đục, pH).
- Phát hiện cảnh báo nhiều mức (advisory / warning / emergency) bằng rule engine và
  tự động điều khiển bơm, cửa xả, còi, bảng cảnh báo qua MQTT.
- Lưu telemetry – event – trạng thái vào InfluxDB; giám sát bằng Grafana và
  ThingsBoard; cung cấp REST API truy vấn và điều khiển thủ công.
- Tích hợp ThingsBoard: đẩy telemetry nhiều trạm (uplink) và nhận RPC điều khiển từ
  xa (downlink). Đóng gói và triển khai bằng Docker Compose.

== Phạm vi và cách tiếp cận

Hệ thống mô phỏng một lưu vực gồm ba trạm `station-01`, `station-02`, `station-03` (đặt
theo các trạm thực trên sông Hồng: Yên Bái → Sơn Tây → Hà Nội). Mỗi trạm có một sensor
node và một actuator node. Đặc trưng cốt lõi của đề tài là kiến trúc lai:
xử lý thời gian thực tại biên cho các tình huống khẩn cấp, kết hợp giám sát toàn lưu
vực trên cloud.

// =============================================================================
= Kiến trúc hệ thống
// =============================================================================//
#dia("d1-architecture.png", [Kiến trúc tổng thể: thiết bị ảo mỗi trạm, broker MQTT,
  edge gateway, InfluxDB, Grafana, REST API và ThingsBoard.]) <fig-arch>

== Các nhóm thành phần

Hệ thống đầy đủ các nhóm chức năng mà một hệ IoT cần: _mô phỏng cảm biến_, _mô phỏng
thiết bị actuator_, _broker_, _gateway_, _cơ sở dữ liệu_, _dashboard_ và _API_. Bảng
@tbl-services liệt kê 11 container và vai trò của chúng.

#figure(
  caption: [Bản đồ dịch vụ — 11 container trong một dự án Docker Compose.],
  table(
    columns: (auto, 1fr),
    align: (left, left),
    table.header[Dịch vụ][Vai trò],
    [`mosquitto`], [MQTT broker biên — trục giao tiếp nội bộ.],
    [`sensor-station-01/02/03`], [Cảm biến ảo mỗi trạm: mực nước, mưa, lưu lượng, độ đục, pH.],
    [`actuator-station-01/02/03`], [Thiết bị actuator ảo: bơm, cửa xả, còi, bảng cảnh báo.],
    [`flood-gateway`], [Gateway: chuẩn hóa, rule engine, ghi InfluxDB, ThingsBoard Gateway.],
    [`influxdb`], [CSDL chuỗi thời gian (telemetry, event, trạng thái).],
    [`grafana`], [Dashboard giám sát tại biên (auto-provisioned).],
    [`flood-api`], [REST API (FastAPI): truy vấn trạng thái + gửi lệnh thủ công.],
    [ThingsBoard], [Đám mây: dashboard, bản đồ, alarm nhiều mức, RPC.],
  ),
) <tbl-services>


Mỗi tầng giải quyết một bài toán khác nhau. Tầng biên tối ưu cho độ trễ thấp và tính
tự chủ: gateway nằm cùng mạng với cảm biến/thiết bị nên luồng "đo → quyết định → điều
khiển" khép kín trong mili-giây và không phụ thuộc Internet. Tầng cloud tối ưu cho
tầm nhìn toàn cục: tổng hợp nhiều trạm, dashboard tập trung, cảnh báo cho người vận hành
và điều khiển từ xa. Cảm biến và thiết bị actuator chỉ giao tiếp qua MQTT cục bộ.

// =============================================================================
= Thiết kế topic và bản tin
// =============================================================================

== Phân cấp topic MQTT

Mọi lưu lượng tại biên dùng lược đồ phân cấp `basin/<station>/<role>/<leaf>`. Lược đồ
này mở rộng theo từng trạm và giúp đăng ký wildcard dễ dàng — gateway chỉ cần
subscribe `basin/+/sensor/telemetry` là nhận được telemetry của mọi trạm.

#dia("d2-topics.png", [Cây topic dưới mỗi trạm và chiều đi của bản tin.], width: 78%) <fig-topics>

#figure(
  caption: [Năm topic tại biên cùng cặp producer → consumer.],
  table(
    columns: (auto, auto),
    align: (left, left),
    table.header[Topic][Producer → Consumer],
    [`basin/<station>/sensor/telemetry`], [sensor → gateway],
    [`basin/<station>/actuator/command`], [gateway / API / RPC → actuator],
    [`basin/<station>/actuator/status`], [actuator → gateway],
    [`basin/<station>/gateway/normalized`], [gateway → subscribers],
    [`basin/<station>/gateway/event`], [gateway → subscribers],
  ),
) <tbl-topics>

Các topic `v1/gateway/*` là một kết nối *riêng* tới broker của ThingsBoard, không thuộc
broker biên (xem Chương 7).

== Định dạng bản tin

Tất cả bản tin là JSON. Bốn loại bản tin chính:

#grid(
  columns: (1fr, 1fr),
  gutter: 12pt,
  [
    *Telemetry* (sensor → gateway):
    ```json
    {
      "device_id": "sensor-station-01",
      "basin_id": "red-river",
      "station_id": "station-01",
      "station_name": "Yên Bái",
      "latitude": 21.705,
      "longitude": 104.869,
      "water_level": 3.42,
      "flow_rate": 12.7,
      "rainfall": 45.0,
      "turbidity": 120.0,
      "ph": 7.1,
      "timestamp": "2026-06-10T10:00:00Z"
    }
    ```
  ],
  [
    *Command* (gateway/API/RPC → actuator):
    ```json
    {
      "station_id": "station-01",
      "target": "pump",
      "action": "on",
      "reason": "water_level_high",
      "timestamp": "2026-06-10T10:00:05Z"
    }
    ```
    *Event* (gateway → subscribers):
    ```json
    {
      "station_id": "station-01",
      "event_type": "flood_warning",
      "severity": "warning",
      "value": 3.42,
      "threshold": 3.0,
      "action_taken": "pump_on,gate_open,board_warning",
      "timestamp": "2026-06-10T10:00:05Z"
    }
    ```
  ],
)

*Status* (actuator → gateway) mang *toàn bộ* trạng thái thiết bị mỗi lần phát:

```json
{
  "device_id": "actuator-station-01", "station_id": "station-01",
  "pump": "on", "gate": "open", "siren": "off", "board": "warning",
  "last_command_reason": "water_level_high", "timestamp": "2026-06-10T10:00:06Z"
}
```

Trong bản tin telemetry, ba trường `station_name`, `latitude`, `longitude` là *mở rộng*
ngoài tập tối thiểu của đề bài — chúng cấp dữ liệu cho widget bản đồ trên ThingsBoard;
gateway chấp nhận và bỏ qua chúng khi không cần.

// =============================================================================
= Luồng Uplink — từ cảm biến lên cloud
// =============================================================================

Uplink là hành trình của một telemetry: sinh ra tại sensor, đi qua broker, được gateway
chuẩn hóa và đánh giá, rồi vừa lưu xuống InfluxDB vừa đẩy lên ThingsBoard
(@fig-uplink).

#dia("d3-uplink.png", [Trình tự uplink: telemetry → chuẩn hóa → lưu trữ + đẩy cloud + rule engine.]) <fig-uplink>

== Mô phỏng cảm biến: một cơn bão chung trên trục thời gian

Hệ thống dựng *kịch bản lưu vực tương quan*, trong đó *một* cơn bão duy nhất chi phối cả ba trạm và *sóng lũ lan dần về
hạ lưu* đồng thời dâng cao hơn — đúng câu chuyện cảnh báo sớm kinh điển (trạm thượng lưu
dâng trước khi thành phố ngập).

Cường độ bão trong một chu kỳ `LOOP_PERIOD` là một hình thang: lặng → dâng → cao nguyên → rút
(@fig-storm).

#dia(
  "d4-storm.png",
  [Lượng mưa theo hình thang trong một chu kỳ bão (lặng 30% → dâng
    15% → cao nguyên 30% → rút 25%).],
  width: 80%,
) <fig-storm>

Mỗi trạm đọc cơn bão đó *trễ* đi một khoảng `lag` (thời gian truyền sóng, tính theo
*phần trăm* của `LOOP_PERIOD`), và *tích phân* mưa trừ thoát nước — đây chính là "xu
hướng":

```python
phase    = (time.time() - SCENARIO_EPOCH - lag) % LOOP_PERIOD
rainfall = PEAK_RAIN * storm_intensity(phase) + gust + noise
# tích phân: mưa làm dâng, thoát nước kéo mực nước về base
level   += gain * rainfall - DRAINAGE_K * (level - base)
```

Hệ số `gain` được *suy ra* từ đỉnh mong muốn (`gain = (peak − base)·K / PEAK_RAIN`), nên
người dùng chỉ cần chỉnh `peak` của mỗi trạm. Kịch bản mặc định là *bão lớn*: cả ba trạm
đều vượt ngưỡng *khẩn cấp* 4.0 m, lệch pha về hạ lưu (@tbl-stations).

#figure(
  caption: [Cấu hình ba trạm (đặt trong `docker-compose.yml`).],
  table(
    columns: (auto, auto, auto, auto, auto, auto),
    align: (left, left, center, center, center, center),
    table.header[Trạm][Tên][Vai trò][`LAG`][`BASE`][`PEAK` (đỉnh)],
    [`station-01`], [Yên Bái], [thượng lưu], [0.0], [1.0 m], [~4.8 m],
    [`station-02`], [Sơn Tây], [trung lưu], [0.06], [1.5 m], [~5.5 m],
    [`station-03`], [Hà Nội], [hạ lưu], [0.12], [2.0 m], [~6.2 m],
  ),
) <tbl-stations>

Các số đo phụ (`flow_rate`, `turbidity`) được suy ra tương quan với mực nước/mưa; `pH`
thường trung tính nhưng thỉnh thoảng lệch về axit (~4%) hoặc kiềm (~4%) để kích hoạt
luật chất lượng nước.

== Chuẩn hóa tại gateway

Với mỗi bản tin, gateway kiểm tra năm trường số bắt buộc (`water_level`, `flow_rate`,
`rainfall`, `turbidity`, `ph`); bản tin lỗi bị loại bỏ kèm log, không
lưu. Sau đó nó tính tốc độ dâng so với số đo trước của chính trạm đó:

```python
delta     = level - prev_level
rise_rate = round(delta / dt * 60.0, 3)   # mét / phút
rising    = delta > RISE_EPSILON          # 0.005 m mỗi mẫu
```

`rising` là cờ mà luật R3 cần. Số đo đã chuẩn hóa được phát lại lên
`basin/<station>/gateway/normalized` và ghi vào InfluxDB (measurement
`water_telemetry`), đồng thời được đẩy lên ThingsBoard và đưa vào rule engine.

// =============================================================================
= Rule engine
// =============================================================================

Rule engine được hiện thực trong `rules.py`:
`evaluate(reading, thresholds)` trả về `(desired, active)`. @fig-pipeline cho thấy vị trí của rule engine trong pipeline
xử lý của gateway.

#dia("d5-gateway-pipeline.png", [Pipeline xử lý của gateway: chuẩn hóa, ghi InfluxDB,
  rule engine (event + lệnh), mirror trạng thái và cập nhật ngưỡng từ xa.]) <fig-pipeline>

== Bốn luật bắt buộc

#figure(
  caption: [Bốn luật, phân mức advisory / warning / emergency.],
  table(
    columns: (auto, 1.3fr, 1.2fr, 1fr),
    align: (center, left, left, left),
    table.header[STT][Điều kiện][Trạng thái mong muốn][Event / mức],
    [R1], [`water_level > 3.0`], [pump *on*, gate *open*, board *warning*], [`flood_warning` / warning],
    [R2], [`water_level > 4.0`], [thêm siren *on*, board *emergency*], [`flood_emergency` / emergency],
    [R3], [`rainfall > 40` và mực nước đang dâng], [board *advisory* (nếu chưa cao hơn)], [`heavy_rain` / advisory],
    [R4], [`turbidity > 100` hoặc `pH < 6` / `pH > 9`], [chỉ cảnh báo], [`water_quality_alert` / warning],
  ),
) <tbl-rules>

```python
def evaluate(reading, thresholds):
    level, rainfall = reading["water_level"], reading["rainfall"]
    rising = reading.get("rising", False)
    desired = {"pump": "off", "gate": "closed", "siren": "off", "board": "normal"}
    active = {}
    # R1 / R2 — mực nước (khẩn cấp đè cảnh báo)
    if level > thresholds["level_emergency"]:
        desired.update(pump="on", gate="open", siren="on", board="emergency")
        active["flood_emergency"] = _event("flood_emergency", "emergency", ...)
    elif level > thresholds["level_warning"]:
        desired.update(pump="on", gate="open", board="warning")
        active["flood_warning"] = _event("flood_warning", "warning", ...)
    # R3 — mưa lớn khi mực nước đang dâng
    if rainfall > thresholds["rainfall_advisory"] and rising:
        if desired["board"] == "normal":
            desired["board"] = "advisory"
        active["heavy_rain"] = _event("heavy_rain", "advisory", ...)
    # R4 — chất lượng nước (độ đục HOẶC pH ngoài dải)
    ...
    return desired, active
```

// =============================================================================
= Luồng Downlink — điều khiển thiết bị
// =============================================================================

Một lệnh có thể đến từ ba nguồn — rule engine (tự động), RPC từ ThingsBoard, hoặc
gọi REST API — nhưng cả ba đều kết thúc thành cùng một bản tin MQTT trên cùng một topic
`basin/<station>/actuator/command`. (@fig-downlink).

#dia("d6-downlink.png", [Downlink: ba nguồn lệnh hội tụ về một control plane MQTT; actuator
  áp dụng rồi phát lại status, gateway ghi InfluxDB và mirror lên cloud.]) <fig-downlink>

== Thiết bị actuator

Mỗi actuator phục vụ một trạm với bốn thiết bị sau một node: *bơm*, *cửa xả/van*, *còi*
và *bảng cảnh báo*. Khi nhận lệnh, nó phân giải `action` *theo từng target*, chấp nhận
vài từ đồng nghĩa để một boolean của RPC, một chuỗi của REST hay một từ của gateway đều
hoạt động:

#figure(
  caption: [Ánh xạ lệnh → trạng thái trong `apply_command`.],
  table(
    columns: (auto, 1.4fr, 1fr),
    align: (left, left, left),
    table.header[`target`][Giá trị `action` chấp nhận][Trạng thái kết quả],
    [`pump`], [`on`/`true`/`open` → bật, còn lại → tắt], [`on` \| `off`],
    [`gate`], [`open`/`on`/`true` → mở, còn lại → đóng], [`open` \| `closed`],
    [`siren`], [`on`/`true` → bật, còn lại → tắt], [`on` \| `off`],
    [`board`], [bất kỳ từ mức nào, lưu nguyên văn], [`normal`..`emergency`],
  ),
) <tbl-actuator>

Actuator phát lại toàn bộ status ngay khi có thay đổi, và heartbeat định
kỳ mỗi `STATUS_INTERVAL` giây kể cả khi không đổi.

// =============================================================================
= Tích hợp ThingsBoard (uplink + RPC)
// =============================================================================

`tb_gateway.py` kết nối tới một ThingsBoard qua MQTT, dùng access token của
thiết bị Gateway làm username.

#figure(
  caption: [Các topic Gateway API mà gateway sử dụng.],
  table(
    columns: (auto, auto, 1fr),
    align: (center, left, left),
    table.header[Chiều][Topic][Mục đích],
    [↑], [`v1/gateway/connect`], [Khai báo mỗi trạm là một sub-device.],
    [↑], [`v1/gateway/telemetry`], [Đẩy telemetry từng trạm + mirror trạng thái actuator.],
    [↑], [`v1/gateway/attributes`], [Gửi `latitude`/`longitude` tĩnh → widget bản đồ.],
    [↓], [`v1/gateway/rpc`], [Nhận lệnh server cho sub-device; trả kết quả.],
    [↕], [`v1/devices/me/attributes`], [Client attrs lên; shared-attribute cập nhật xuống.],
  ),
) <tbl-tb-topics>

== Điều khiển từ xa: RPC → lệnh cục bộ

Một nút RPC trên ThingsBoard gửi tới thiết bị trạm → TB định tuyến về gateway →
`rpc_handler` dịch thành lệnh MQTT cục bộ (đúng topic mà rule engine dùng) rồi trả
`{"success": true}` (@fig-rpc). Bốn phương thức: `setPump`, `setGate`, `setSiren` (boolean)
và `setBoard` (chuỗi).

#dia(
  "d7-rpc.png",
  [Trình tự RPC: nút trên ThingsBoard → gateway dịch sang lệnh MQTT →
    actuator → trả kết quả về cloud.],
  width: 86%,
) <fig-rpc>

== Chỉnh ngưỡng từ xa bằng shared attributes

Sáu ngưỡng cảnh báo có thể chỉnh từ thingsboard mà không cần khởi động lại, bằng cách đặt
shared attribute trùng tên trên thiết bị gateway (`level_warning`, `level_emergency`,
`rainfall_advisory`, `turbidity_max`, `ph_min`, `ph_max`). Một
thay đổi từ xa chỉ cần tới được gateway là tick telemetry kế tiếp áp dụng cho mọi trạm.

Hai cơ chế phối hợp (@fig-shared): TB đẩy khi thay đổi, và gateway đọc một lần khi kết
nối để nạp các giá trị người vận hành đặt trước khi gateway online. Gateway còn phản
hồi giá trị đang áp dụng dưới dạng client attribute `active_<key>` để xác nhận.

#dia(
  "d8-shared-attrs.png",
  [Chỉnh ngưỡng từ xa: push khi đổi + đọc một lần khi kết nối,
    và xác nhận bằng client attribute `active_*`.],
  width: 92%,
) <fig-shared>

== Dashboard, bản đồ và alarm trên ThingsBoard

Trên đám mây, hệ thống cung cấp: biểu đồ mực nước theo thời gian cho ba trạm với đường
cảnh báo 3.0/4.0 m; bản đồ OpenStreetMap với ba trạm tô màu theo mực nước (hai Hình bên
dưới); các nút RPC `setPump`/`setGate`/`setSiren` cho từng trạm và một Alarm nhiều mức
dựng bằng Rule Chain — `water_level > 4.0` → CRITICAL, `> 3.0` → WARNING, trở lại `≤ 3.0`
→ xóa alarm (@fig-tb-rpc).

#grid(
  columns: (1fr, 1fr),
  gutter: 10pt,
  shot("s7-tb-chart_1.png", [ThingsBoard — mực nước theo thời gian.], width: 100%),
  shot("s8-tb-map_1.png", [ThingsBoard — bản đồ ba trạm theo màu mức.], width: 100%),
)
#shot("s9-tb-rpc-alarm_1.png", [ThingsBoard — nút RPC điều khiển.]) <fig-tb-rpc>
#shot("alrarm.png", [ThingsBoard — Bảng Alarm]) <fig-tb-alarm>

// =============================================================================
= Lưu trữ và giám sát
// =============================================================================

== Lược đồ InfluxDB


#figure(
  caption: [Lược đồ InfluxDB — ba measurement (org `navis`, bucket `flood`).],
  table(
    columns: (auto, 1fr, 1.4fr),
    align: (left, left, left),
    table.header[Measurement][Tag][Field],
    [`water_telemetry`],
    [`basin_id`, `station_id`],
    [`water_level`, `flow_rate`, `rainfall`, `turbidity`, `ph`, `rise_rate`],

    [`gateway_events`], [`station_id`, `event_type`, `severity`], [`value`, `threshold`, `action_taken`],
    [`actuator_status`], [`station_id`], [`pump`, `gate`, `siren`, `board`, `last_command_reason`],
  ),
) <tbl-influx>


== Dashboard Grafana

Sáu panel đáp ứng đủ yêu cầu trực quan hóa của đề bài (@tbl-grafana).

#figure(
  caption: [Sáu panel của dashboard Grafana.],
  table(
    columns: (auto, 1fr),
    align: (center, left),
    table.header[STT][Panel],
    [1], [Mực nước theo trạm, kèm đường warning 3.0 và emergency 4.0.],
    [2], [Lượng mưa theo trạm (mm/h), vẽ dạng đường.],
    [3], [Lưu lượng + độ đục (trục trái) và pH (trục phải), lặp theo trạm.],
    [4], [Trạng thái bơm/cửa/còi/bảng dạng state timeline, lặp theo trạm.],
    [5], [Số event theo mức advisory/warning/emergency theo thời gian.],
    [6], [Bảng event gần nhất: `station_id`, `event_type`, `severity`, `action_taken`.],
  ),
) <tbl-grafana>

#shot("s3-grafana.png", [Mực nước + đường ngưỡng.], width: 100%),
#shot("s5-grafana-rain-quality_1.png", [Lượng mưa], width: 100%),
#shot("quality.png", [Chất lượng nước], width: 100%),
#shot("s6-grafana-events.png.png", [Số event theo mức + bảng event.], width: 100%),

== REST API (FastAPI)


#figure(
  caption: [Năm endpoint của REST API.],
  table(
    columns: (auto, 1.2fr, 1fr),
    align: (left, left, left),
    table.header[Method][Endpoint][Mục đích],
    [`GET`], [`/health`], [API healthcheck + InfluxDB.],
    [`GET`], [`/stations`], [Mọi trạm: mực nước + bảng mới nhất.],
    [`GET`], [`/stations/{id}/state`], [Telemetry + trạng thái actuator mới nhất.],
    [`GET`], [`/stations/{id}/events`], [Event gần đây (`?limit=&hours=`).],
    [`POST`], [`/stations/{id}/command`], [Gửi lệnh thủ công (→ MQTT).],
  ),
) <tbl-api>

```bash
# Liệt kê trạng thái mọi trạm
curl http://localhost:8000/stations
# Gửi lệnh thủ công — cùng control plane với gateway & RPC
curl -X POST http://localhost:8000/stations/station-03/command \
     -H "Content-Type: application/json" \
     -d '{"target":"pump","action":"on","reason":"manual_test"}'
```

#shot(
  "api.png",
  [Tài liệu Swagger tại `http://localhost:8000/docs`.],
  width: 80%,
) <fig-swagger>

// =============================================================================
= Triển khai Docker Compose
// =============================================================================

Toàn bộ hệ thống khởi chạy bằng một lệnh. Mỗi service tự lập trình có Dockerfile riêng;
cấu hình đọc từ biến môi trường (`.env`); các service dùng
*volume* cho InfluxDB/Grafana và nói chuyện qua mạng `flood-net`.

== Tham số hóa qua biến môi trường

```yaml
sensor-station-02:
  build: ./sensor
  container_name: sensor-station-02
  env_file: .env
  environment:
    STATION_ID: station-02
    STATION_NAME: Sơn Tây
    STATION_ROLE: midstream
    STATION_LAT: "21.1480"
    STATION_LON: "105.5040"
    STATION_LAG: "0.06"      # trễ 6% chu kỳ → sóng về hạ lưu
    STATION_BASE: "1.5"      # mực nước nghỉ
    STATION_PEAK: "5.5"      # đỉnh khi mưa cực đại → mức nghiêm trọng
  depends_on: [mosquitto]
  networks: [flood-net]
```

Tệp `.env` giữ cấu hình *dùng chung* (broker, InfluxDB, ngưỡng, kịch bản bão). Ví dụ một phần:

```env
MQTT_BROKER=mosquitto
INFLUXDB_URL=http://influxdb:8086
INFLUXDB_ORG=navis
INFLUXDB_BUCKET=flood
LEVEL_WARNING=3.0
LEVEL_EMERGENCY=4.0
TB_HOST=            # để trống = chạy edge-only, không đồng bộ cloud
```

== Vận hành

```bash
docker compose up -d --build          # build & chạy toàn bộ stack
docker compose ps                     # kiểm tra mọi service Up
docker compose logs -f flood-gateway  # xem EVENT / CMD / [TB]
docker compose down                   # dừng (thêm -v để xóa volume)
```

Trong một chu kỳ bão (`LOOP_PERIOD`, mặc định 300 s), cả ba trạm lần lượt vượt ngưỡng
warning rồi emergency — thượng lưu `station-01` dâng trước, rồi `station-02`, cuối cùng
`station-03` đỉnh cao nhất — và ta quan sát gateway phát event, điều khiển thiết bị.

#grid(
  columns: (1fr, 1fr),
  gutter: 10pt,
  shot("s1-docker.png", [`docker compose ps` — mọi service Up.], width: 100%),
  shot("se.png", [Log gateway — các dòng EVENT và CMD.], width: 100%),
)<fig-ops>

== Khả năng phục hồi

Mọi thành phần tự kết nối lại: sensor/actuator/gateway thử lại broker mỗi 5 s; gateway
chờ InfluxDB health `pass` trước khi ghi.

// =============================================================================
= Trả lời các câu hỏi bắt buộc
// =============================================================================

/ 1. Vì sao cảnh báo lũ cần xử lý tại edge thay vì chờ cloud?: Vì độ trễ và tính sẵn
  sàng. Vòng "đo → quyết định → điều khiển" khép kín ngay tại trạm trong mili-giây, và
  vẫn chạy khi mất kết nối lên trung tâm — đúng lúc thiên tai dễ làm đứt đường truyền.
  Chờ cloud sẽ thêm độ trễ mạng, trong khi vài
  phút cảnh báo sớm vô cùng quan trọng.

/ 2. Nhóm thiết kế topic và message format thế nào?: Topic phân cấp
  `basin/<station>/<role>/<leaf>` (@tbl-topics) cho phép tách theo trạm/vai trò
  và subscribe wildcard `basin/+/sensor/telemetry`. Bản tin là JSON với bốn loại:
  telemetry, command, status, event — mỗi loại có tập trường cố định, kèm `station_id` và
  `timestamp` để truy vết.

/ 3. Rule engine phân mức cảnh báo ra sao?: Bốn luật R1–R4 (@tbl-rules) ánh xạ điều
  kiện sang ba mức *advisory / warning / emergency*.

/ 4. Khi mực nước vượt ngưỡng, luồng telemetry → cảnh báo → điều khiển diễn ra thế nào?:
  Sensor publish telemetry → gateway chuẩn hóa và tính `rise_rate` → `rules.evaluate()`
  sinh điều kiện active và trạng thái mong muốn → gateway phát *event* (cho điều kiện mới)
  và gửi *lệnh* (cho thiết bị đổi trạng thái) → actuator áp dụng và phát lại *status* →
  gateway ghi InfluxDB, Grafana hiển thị, đồng thời mirror lên ThingsBoard (@fig-downlink).

/ 5. Gateway đóng vai trò ThingsBoard Gateway như thế nào?: Nó kết nối ThingsBoard bằng
  MQTT với *username = access token* của thiết bị Gateway, gộp nhiều sub-device qua
  một kết nối: khai báo trạm (`v1/gateway/connect`), đẩy telemetry nhiều trạm cùng lúc
  (`v1/gateway/telemetry`), và nhận RPC (`v1/gateway/rpc`) rồi dịch thành lệnh MQTT cục
  bộ (@tbl-tb-topics).

/ 6. Vì sao vẫn cần đẩy dữ liệu lên cloud dù đã xử lý ở edge?: Để có tầm nhìn toàn lưu
  vực mà một trạm đơn lẻ không có: dashboard tập trung, bản đồ nhiều trạm, alarm và thông
  báo cho người vận hành, lưu trữ/đối chiếu dài hạn, điều khiển từ xa và phối hợp liên
  trạm.

/ 7. Vì sao container không nên dùng `localhost` để gọi service khác?: Vì mỗi container có
  *network namespace riêng* — `localhost` trỏ về *chính container đó*, không phải host hay
  container khác. Trong Docker Compose, các service phải gọi nhau *bằng tên dịch vụ*
  (`mosquitto`, `influxdb`) để Docker DNS phân giải đúng địa chỉ trên mạng `flood-net`.

/ 8. Muốn mở rộng giám sát toàn thành phố trên ThingsBoard cần thay đổi gì?: Thêm trạm chỉ
  là thêm khối env trong compose; phía cloud dùng *device profile* + *rule chain* dùng
  chung, tổ chức asset hierarchy (lưu vực → quận → trạm) để dashboard và alarm theo
  cấp, đặt ngưỡng theo từng trạm qua shared attributes, và phân quyền tenant/customer
  cho từng đơn vị vận hành.

// =============================================================================
= Đánh giá và kết luận
// =============================================================================

== Phân công công việc

#figure(
  caption: [Phân công cho nhóm ba thành viên.],
  table(
    columns: (auto, auto, 1.4fr),
    align: (left, left, left),
    table.header[Thành viên][Họ tên — MSSV][Hạng mục phụ trách],
    [SV1], [Dương Hữu Huynh], [Virtual sensor, virtual actuator, thiết kế topic/bản tin.],
    [SV2], [Nông Đức Huy], [Edge gateway, rule engine, ghi InfluxDB.],
    [SV3], [Bùi Phạm Sơn Hà], [Tích hợp ThingsBoard + dashboard + alarm, REST API, Docker Compose, Grafana, README.],
  ),
) <tbl-phancong>

== Các yêu cầu nâng cao

#figure(
  caption: [Hiện trạng các yêu cầu nâng cao (cộng điểm).],
  table(
    columns: (1.3fr, auto, 1.2fr),
    align: (left, center, left),
    table.header[Yêu cầu][Mức][Ghi chú],
    [Bản đồ trạm + mức cảnh báo theo màu trên TB], [Đã đạt], [Widget map + marker tô màu theo mực nước.],
    [Shared Attributes chỉnh ngưỡng từ xa], [Đã đạt], [6 ngưỡng, áp dụng nóng không restart.],
    [Reconnect khi mất kết nối MQTT/ThingsBoard], [Đã đạt], [Mọi thành phần có vòng thử lại.],
    [Alarm nhiều mức trên ThingsBoard], [Đã đạt], [Rule Chain: WARNING / CRITICAL theo ngưỡng.],
    [Dự báo xu hướng mực nước ngắn hạn], [Một phần], [Đã tính `rise_rate` (m/phút) — nền cho dự báo.],
    [Unit test cho rule engine], [Một phần], [Engine là hàm thuần, tách I/O — sẵn sàng test; có lệnh kiểm thử nhanh.],
    [Health check cho service trong Compose],
    [Một phần],
    [Gateway chờ InfluxDB health `pass`; chưa khai báo `healthcheck` trong compose.],

    [Thông báo email/Telegram khi emergency], [Hướng mở rộng], [Thêm node notification vào Rule Chain TB.],
    [Phát hiện `sensor_offline` / mất kết nối trạm], [Hướng mở rộng], [Theo dõi tuổi `prev_ts` trong `STATE`.],
  ),
) <tbl-nangcao>

== Hạn chế và hướng phát triển

Ngưỡng hiện là toàn lưu vực (một bộ chung); có thể nâng thành theo từng trạm qua
shared attributes per-device. Chưa có cảnh báo sensor offline và thông báo
email/Telegram — cả hai đều khả thi bằng cách bổ sung logic ở gateway và node Rule Chain.
Để giám sát quy mô thành phố, cần tổ chức asset hierarchy và phân quyền tenant.

== Kết luận

Hệ thống đã hiện thực đầy đủ một hệ thống IoT hai chiều trên hạ tầng ảo hóa hoàn
toàn: nhiều virtual sensor sinh telemetry tương quan theo một kịch bản bão thực tế; một
edge gateway chuẩn hóa, chạy rule engine đa mức, tự động điều khiển thiết bị, ghi InfluxDB
và hiển thị Grafana tại biên; đồng thời đóng vai trò ThingsBoard Gateway để đẩy
telemetry và nhận RPC từ đám mây. Toàn bộ khởi chạy bằng một lệnh Docker Compose. Qua
đó, đề tài làm rõ giá trị của xử lý thời gian thực tại biên cho các tình huống khẩn cấp,
kết hợp với giám sát toàn lưu vực trên đám mây.

Toàn bộ source code, tài liệu được lưu trữ tại: https://github.com/betty2310/flood-warning-system
