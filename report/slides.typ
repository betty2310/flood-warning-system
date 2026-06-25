// =============================================================================
//  SLIDE — Virtual Smart Water & Flood Early-Warning Gateway
//  Biên dịch:  typst compile slides.typ
//  Bản cô đọng của báo cáo main.typ, dùng template diatypst.
//  Quy ước hình: mỗi hình chiếm trọn chiều ngang slide, không bố cục cạnh nhau.
// =============================================================================

#import "@preview/diatypst:0.9.3": *

#set text(lang: "vi")
#set outline(depth: 1)

#show: slides.with(
  title: "Virtual Smart Water & Flood Early-Warning Gateway",
  subtitle: "Hanoi University of Science and Technology",
  date: "Hanoi, 06/2026",
  authors: ("Dương Hữu Huynh", "Nông Đức Huy", "Bùi Phạm Sơn Hà"),
  ratio: 16 / 9,
  layout: "medium",
  title-color: blue.darken(60%),
  toc: true,
  footer-subtitle: "group 2",
  count: "dot-section",
  theme: "full",
)

// ---- helpers --------------------------------------------------------------
// imgw: hình rộng → chiếm trọn chiều ngang slide.
// imgh: hình cao → căn giữa, giới hạn theo chiều cao để vừa slide.
#let imgw(path) = align(center, image("images/" + path, width: 100%))
#let imgh(path, h) = align(center, image("images/" + path, height: h))
#let insight(body) = align(center)[
  #block(
    fill: blue.lighten(86%),
    inset: 9pt,
    radius: 5pt,
    width: 94%,
  )[#text(weight: "bold", fill: blue.darken(40%))[#body]]
]

// =============================================================================
= Giới thiệu
// =============================================================================

== Bối cảnh & Động lực

- *Ngập lụt* đô thị và lũ trên sông gây thiệt hại lớn về người và tài sản;
  *thời gian là yếu tố sống còn* — cảnh báo sớm vài phút đủ để bơm tiêu úng,
  mở cửa xả, hú còi sơ tán.
- *Phản ứng tại biên (edge):* một gateway đặt cạnh cảm biến phát hiện mực nước
  vượt ngưỡng và *lập tức* kích hoạt thiết bị, *không phụ thuộc* đường truyền lên
  server.
- *Giám sát toàn lưu vực:* dữ liệu vẫn đẩy lên cloud để trung tâm theo dõi toàn
  bộ lưu vực và ra lệnh từ xa.

#v(0.4em)
/ *Kiến trúc lai*: xử lý thời gian thực tại biên + giám sát toàn cục trên cloud.


== Mục tiêu & Phạm vi

#grid(
  columns: (1fr, 1fr),
  column-gutter: 1.4em,
  [
    *Mục tiêu*
    - Nhiều *virtual sensor* + một *edge gateway* nhận telemetry MQTT đa trạm.
    - Thiết kế *topic hierarchy* & message format; chuẩn hóa dữ liệu nước.
    - *Rule engine* cảnh báo nhiều mức + tự động điều khiển actuator.
    - Lưu *InfluxDB*, giám sát *Grafana / ThingsBoard*, cung cấp *REST API*.
    - Tích hợp *ThingsBoard* (uplink + RPC); đóng gói *Docker Compose*.
  ],
  [
    *Phạm vi — lưu vực sông Hồng*
    - `station-01` — Yên Bái _(thượng lưu)_
    - `station-02` — Sơn Tây _(trung lưu)_
    - `station-03` — Hà Nội _(hạ lưu)_

    #v(0.3em)
    - Mỗi trạm: *1 sensor node + 1 actuator node*.
    - *Toàn bộ phần mềm* — thiết bị ảo hoá bằng Docker.
  ],
)

// =============================================================================
= Kiến trúc hệ thống
// =============================================================================

== Kiến trúc tổng thể

#imgw("d1-architecture.png")

#v(0.3em)
Thiết bị ảo mỗi trạm → *broker MQTT* → *edge gateway* → InfluxDB / Grafana /
REST API, đồng thời *mirror* lên ThingsBoard.

== Thành phần hệ thống — 11 container

#align(center)[
  #text(size: 0.82em)[
    #table(
      columns: (auto, 1fr),
      align: (left, left),
      stroke: 0.5pt + gray,
      table.header[*Dịch vụ*][*Vai trò*],
      [`mosquitto`], [MQTT broker biên — trục giao tiếp nội bộ.],
      [`sensor-station-01/02/03`], [Cảm biến ảo: mực nước, mưa, lưu lượng, độ đục, pH.],
      [`actuator-station-01/02/03`], [Thiết bị: bơm, cửa xả, còi, bảng cảnh báo.],
      [`flood-gateway`], [Chuẩn hóa, rule engine, ghi InfluxDB, ThingsBoard Gateway.],
      [`influxdb`], [CSDL chuỗi thời gian (telemetry, event, trạng thái).],
      [`grafana`], [Dashboard giám sát tại biên (auto-provisioned).],
      [`flood-api`], [REST API (FastAPI): truy vấn trạng thái + lệnh thủ công.],
      [*ThingsBoard*], [Cloud: dashboard, bản đồ, alarm nhiều mức, RPC.],
    )
  ]
]

// =============================================================================
= Thiết kế topic & bản tin
// =============================================================================

== Phân cấp topic MQTT

Lược đồ `basin/<station>/<role>/<leaf>` — mở rộng theo trạm, đăng ký *wildcard*
dễ dàng: gateway chỉ cần `basin/+/sensor/telemetry`.

#align(center)[
  #text(size: 0.8em)[
    #table(
      columns: (auto, auto),
      align: (left, left),
      stroke: 0.5pt + gray,
      table.header[*Topic*][*Producer → Consumer*],
      [`basin/<station>/sensor/telemetry`], [sensor → gateway],
      [`basin/<station>/actuator/command`], [gateway / API / RPC → actuator],
      [`basin/<station>/actuator/status`], [actuator → gateway],
      [`basin/<station>/gateway/normalized`], [gateway → subscribers],
      [`basin/<station>/gateway/event`], [gateway → subscribers],
    )
  ]
]

#pagebreak()

#imgw("d2-topics.png")

#v(0.3em)
#align(center)[#text(size: 0.85em)[Cây topic dưới mỗi trạm và chiều đi của bản tin.]]

== Định dạng bản tin — JSON

Bốn loại bản tin chính: *telemetry · command · status · event*.

#grid(
  columns: (1fr, 1fr),
  column-gutter: 1em,
  [
    *Telemetry* (sensor → gateway):
    ```json
    {
      "station_id": "station-01",
      "station_name": "Yên Bái",
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
    *Event* (gateway → subscribers):
    ```json
    {
      "station_id": "station-01",
      "event_type": "flood_warning",
      "severity": "warning",
      "value": 3.42,
      "threshold": 3.0,
      "action_taken": "pump_on,gate_open",
      "timestamp": "2026-06-10T10:00:05Z"
    }
    ```
  ],
)

// =============================================================================
= Luồng dữ liệu & Rule engine
// =============================================================================

== Luồng Uplink — từ cảm biến lên cloud

#imgh("d3-uplink.png", 84%)

#v(0.2em)
#align(center)[#text(size: 0.85em)[Telemetry: sensor → broker → gateway *chuẩn hóa
  & đánh giá* → lưu *InfluxDB* + đẩy *ThingsBoard* + đưa vào *rule engine*.]]

== Kịch bản bão tương quan

- *Một* cơn bão duy nhất chi phối *cả 3 trạm*; sóng lũ *lan dần về hạ lưu* và
  dâng cao hơn — đúng câu chuyện cảnh báo sớm kinh điển.
- Cường độ bão hình thang: *lặng → dâng → cao nguyên → rút*.
- Mỗi trạm đọc bão *trễ* một khoảng `lag`; *tích phân* mưa trừ thoát nước =
  "xu hướng" mực nước.

#pagebreak()

#imgh("d4-storm.png", 80%)
#align(center)[#text(size: 0.85em)[Lượng mưa hình thang trong một chu kỳ bão
  (lặng 30% → dâng 15% → cao nguyên 30% → rút 25%).]]

#pagebreak()

Hệ số `gain` được *suy ra* từ đỉnh mong muốn, nên chỉ cần chỉnh `peak` mỗi trạm:

```python
phase    = (time.time() - SCENARIO_EPOCH - lag) % LOOP_PERIOD
rainfall = PEAK_RAIN * storm_intensity(phase) + gust + noise
# tích phân: mưa làm dâng, thoát nước kéo mực nước về base
level   += gain * rainfall - DRAINAGE_K * (level - base)
```

#align(center)[
  #text(size: 0.8em)[
    #table(
      columns: (auto, auto, auto, auto, auto, auto),
      align: (left, left, center, center, center, center),
      stroke: 0.5pt + gray,
      table.header[*Trạm*][*Tên*][*Vai trò*][`LAG`][`BASE`][`PEAK`],
      [`station-01`], [Yên Bái], [thượng lưu], [0.0], [1.0 m], [~4.8 m],
      [`station-02`], [Sơn Tây], [trung lưu], [0.06], [1.5 m], [~5.5 m],
      [`station-03`], [Hà Nội], [hạ lưu], [0.12], [2.0 m], [~6.2 m],
    )
  ]
]

== Rule engine — bốn luật phân mức

#align(center)[
  #text(size: 1em)[
    #table(
      columns: (auto, 1.3fr, 1.2fr, 1fr),
      align: (center, left, left, left),
      stroke: 0.5pt + gray,
      table.header[*STT*][*Điều kiện*][*Trạng thái mong muốn*][*Event / mức*],
      [R1], [`water_level > 3.0`], [pump *on*, gate *open*, board *warning*], [`flood_warning` / warning],
      [R2], [`water_level > 4.0`], [thêm siren *on*, board *emergency*], [`flood_emergency` / emergency],
      [R3], [`rainfall > 40` và đang dâng], [board *advisory* (nếu chưa cao hơn)], [`heavy_rain` / advisory],
      [R4], [`turbidity > 100` hoặc pH lệch], [chỉ cảnh báo], [`water_quality_alert` / warning],
    )
  ]
]

#v(0.3em)
#insight[`evaluate(reading, thresholds)` → `(desired, active)`]

== Luồng Downlink — điều khiển thiết bị

#imgh("d6-downlink.png", 82%)

#v(0.2em)
#align(center)[#text(size: 0.85em)[Ba nguồn lệnh — *rule engine* / *RPC* / *REST
  API* — hội tụ về *một* topic `actuator/command`; actuator áp dụng rồi phát lại
  *status*.]]

// =============================================================================
= Tích hợp ThingsBoard
// =============================================================================

== ThingsBoard Gateway

`tb_gateway.py` kết nối ThingsBoard qua MQTT, *username = access token* của thiết
bị Gateway, gộp nhiều sub-device qua một kết nối.

#align(center)[
  #text(size: 0.82em)[
    #table(
      columns: (auto, auto, 1fr),
      align: (center, left, left),
      stroke: 0.5pt + gray,
      table.header[*Chiều*][*Topic*][*Mục đích*],
      [↑], [`v1/gateway/connect`], [Khai báo mỗi trạm là một sub-device.],
      [↑], [`v1/gateway/telemetry`], [Đẩy telemetry từng trạm + mirror trạng thái.],
      [↑], [`v1/gateway/attributes`], [Gửi `latitude`/`longitude` → widget bản đồ.],
      [↓], [`v1/gateway/rpc`], [Nhận lệnh server cho sub-device; trả kết quả.],
      [↕], [`v1/devices/me/attributes`], [Client attrs lên; shared-attribute xuống.],
    )
  ]
]

== Điều khiển từ xa — RPC → lệnh cục bộ

#imgw("d7-rpc.png")

#v(0.2em)
Nút trên ThingsBoard → gateway *dịch* sang lệnh MQTT (đúng topic rule engine
dùng) → actuator → trả `{"success": true}`. Bốn phương thức: `setPump`, `setGate`,
`setSiren`, `setBoard`.

== Chỉnh ngưỡng từ xa — Shared Attributes

#imgh("d8-shared-attrs.png", 72%)

#v(0.2em)
Sáu ngưỡng (`level_warning`, `level_emergency`, …) chỉnh từ xa, *áp dụng nóng
không restart*; gateway xác nhận giá trị đang dùng bằng client attribute `active_*`.

== Bản đồ trạm & Alarm

#imgh("s8-tb-map_1.png", 76%)

#v(0.2em)
#align(center)[Bản đồ OpenStreetMap — ba trạm tô màu theo mực nước.]

#imgh("s7-tb-chart_1.png", 75%)
#v(0.2em)
#align(center)[Mực nước theo thời gian.]

#imgh("alrarm.png", 75%)
#v(0.2em)
#align(center)[Bảng Alarm.]

// =============================================================================
= Lưu trữ, giám sát & triển khai
// =============================================================================

== Lược đồ InfluxDB

#align(center)[
  #text(size: 0.84em)[
    #table(
      columns: (auto, 1fr, 1.4fr),
      align: (left, left, left),
      stroke: 0.5pt + gray,
      table.header[*Measurement*][*Tag*][*Field*],
      [`water_telemetry`],
      [`basin_id`, `station_id`],
      [`water_level`, `flow_rate`, `rainfall`, `turbidity`, `ph`, `rise_rate`],

      [`gateway_events`], [`station_id`, `event_type`, `severity`], [`value`, `threshold`, `action_taken`],
      [`actuator_status`], [`station_id`], [`pump`, `gate`, `siren`, `board`],
    )
  ]
]

== Dashboard Grafana

#imgw("s3-grafana.png")
#imgw("s5-grafana-rain-quality_1.png")
#imgw("quality.png")
#imgw("s6-grafana-events.png.png")

#v(0.2em)
#align(center)[#text(size: 0.85em)[Mực nước theo trạm kèm đường warning 3.0 m và
  emergency 4.0 m — sáu panel phủ đủ yêu cầu trực quan hóa.]]

== REST API (FastAPI)

#grid(
  columns: (1fr, 1fr),
  column-gutter: 1.2em,
  align: horizon,
  [
    #text(size: 0.84em)[
      #table(
        columns: (auto, 1.2fr),
        align: (left, left),
        stroke: 0.5pt + gray,
        table.header[*Method*][*Endpoint*],
        [`GET`], [`/health`],
        [`GET`], [`/stations`],
        [`GET`], [`/stations/{id}/state`],
        [`GET`], [`/stations/{id}/events`],
        [`POST`], [`/stations/{id}/command`],
      )
    ]
  ],
  [
    Năm endpoint: healthcheck, liệt kê trạng thái mọi trạm, trạng thái một trạm,
    event gần đây và *gửi lệnh thủ công* (cùng control plane với gateway & RPC).

    ```bash
    curl -X POST .../station-03/command \
      -d '{"target":"pump","action":"on"}'
    ```
  ],
)

#pagebreak()

#imgh("api.png", 80%)
#align(center)[#text(size: 0.85em)[Tài liệu Swagger tại `http://localhost:8000/docs`.]]

== Triển khai Docker Compose

- *Một lệnh* khởi chạy toàn bộ stack; tham số hóa qua biến môi trường
  (`.env` + khối `environment:`).
- *Khả năng phục hồi:* mọi thành phần tự thử lại broker mỗi 5 s; gateway chờ
  InfluxDB health `pass` trước khi ghi.

```bash
docker compose up -d --build          # build & chạy toàn bộ stack
docker compose ps                     # kiểm tra mọi service Up
docker compose logs -f flood-gateway  # xem EVENT / CMD / [TB]
docker compose down                   # dừng (thêm -v để xóa volume)
```

== Khởi chạy & nhật ký gateway

#imgw("se.png")

#v(0.2em)
#align(center)[#text(size: 0.85em)[Log gateway — các dòng *EVENT* và *CMD*: cả ba
  trạm lần lượt vượt ngưỡng warning rồi emergency, gateway phát event và điều
  khiển thiết bị.]]

// =============================================================================
= Kết luận
// =============================================================================

== Kết quả đạt được

- Hiện thực đầy đủ một hệ *IoT hai chiều* trên hạ tầng *ảo hóa hoàn toàn*.
- Nhiều *virtual sensor* sinh telemetry tương quan theo kịch bản bão thực tế.
- *Edge gateway:* chuẩn hóa, rule engine đa mức, tự động điều khiển, ghi
  InfluxDB, hiển thị Grafana tại biên.
- Đóng vai trò *ThingsBoard Gateway:* uplink đa trạm + RPC + shared attributes.
- *Một lệnh Docker Compose* khởi chạy toàn bộ.

#v(0.3em)
#insight[Yêu cầu nâng cao đã đạt: bản đồ màu · shared attributes · reconnect · alarm nhiều mức.]

== Hạn chế & Hướng phát triển

- Ngưỡng hiện *toàn lưu vực* → nâng thành *per-station* qua shared attributes
  per-device.
- Chưa có cảnh báo *sensor offline* và *thông báo email/Telegram* — khả thi bằng
  logic gateway + node Rule Chain.
- *Dự báo xu hướng:* đã tính `rise_rate` (m/phút) làm nền cho dự báo ngắn hạn.
- *Quy mô thành phố:* tổ chức asset hierarchy (lưu vực → quận → trạm) + phân
  quyền tenant/customer.

==

#figure(
  caption: [Phân công cho nhóm ba thành viên.],
  table(
    columns: (auto, auto, 1.4fr),
    align: (left, left, left),
    table.header[Thành viên][Họ tên — MSSV][Hạng mục phụ trách],
    [SV1], [Dương Hữu Huynh], [Virtual sensor, virtual actuator, thiết kế topic/bản tin, Docker compose],
    [SV2], [Nông Đức Huy], [Edge gateway, rule engine, ghi InfluxDB, Tích hợp Thingsboard, Rest API],
    [SV3], [Bùi Phạm Sơn Hà], [Các giao diện dashboard Thingsboard, Grafana, Báo cáo, README.],
  ),
) <tbl-phancong>

==

#v(2em)
#align(center)[
  #text(size: 1.6em, weight: "bold", fill: blue.darken(60%))[Cảm ơn đã lắng nghe!]

  #v(1em)
  #text(size: 0.9em)[Toàn bộ source code & tài liệu:]

  #v(0.3em)
  #link("https://github.com/betty2310/flood-warning-system")[
    `github.com/betty2310/flood-warning-system`
  ]
]
