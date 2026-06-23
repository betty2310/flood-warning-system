# Virtual Smart Water & Flood Early-Warning Gateway

# Yêu cầu chung

Mỗi nhóm xây dựng một hệ thống IoT hoàn chỉnh ở mức phần mềm, trong đó toàn bộ thiết bị vật lý (sensor, actuator, gateway) được giả lập bằng chương trình Python chạy trong container Docker. Hệ thống phải thể hiện được cả hai chiều dữ liệu đã học: chiều uplink (telemetry từ thiết bị lên cloud) và chiều downlink (lệnh điều khiển RPC từ cloud xuống thiết bị).

Điểm khác biệt cốt lõi so với labwork cơ bản: hệ thống dùng kiến trúc lai (hybrid). Một Edge IoT Gateway tự lập trình đứng giữa, vừa xử lý dữ liệu cục bộ tại biên (normalize, rule engine, lưu InfluxDB, dashboard Grafana), vừa đóng vai trò ThingsBoard Gateway đẩy dữ liệu nhiều thiết bị con lên ThingsBoard Cloud và nhận lệnh RPC từ cloud để điều khiển actuator.

### Kiến trúc lai bắt buộc

Mọi đề tài đều theo mô hình sau (chi tiết hóa theo từng lĩnh vực ở mỗi đề tài):

1. Virtual sensor (Python/Java/C.., container): mỗi node sinh telemetry định kỳ, publish JSON lên Mosquitto broker cục bộ.

2. Virtual actuator (Python/Java/C.., container): subscribe topic lệnh, cập nhật trạng thái, publish lại status.

3. Mosquitto MQTT broker (container): trục giao tiếp nội bộ tại edge.

4. Edge IoT Gateway (Python/Java/C.., container) — thành phần quan trọng nhất:
   • Subscribe toàn bộ telemetry từ các node; validate và normalize dữ liệu.
   • Chạy rule engine ( ≥ 4 luật), sinh event bất thường, gửi command tự động xuống actuator.
   • Ghi telemetry/event/status vào InfluxDB.
   • Hoạt động như ThingsBoard Gateway: connect các sub-device, đẩy telemetry lên ThingsBoard, nhận RPC từ ThingsBoard và chuyển thành command MQTT cục bộ.

5. InfluxDB (container): time-series database tại edge.

6. Grafana (container): dashboard giám sát đọc dữ liệu từ InfluxDB.

7. FastAPI REST API (Python/Java/C.., container): truy vấn trạng thái và gửi lệnh thủ công; tham chiếu được tới ThingsBoard REST API (đăng nhập JWT).

8. ThingsBoard Cloud: nền tảng IoT đám mây — dashboard, Rule Chain, Alarm theo ngưỡng và RPC điều khiển từ xa.

### ThingsBoard Gateway API (dùng chung)

Gateway kết nối ThingsBoard bằng MQTT với username = ACCESS_TOKEN của một thiết bị kiểu Gateway. Các topic chuẩn

```
# Announce a sub-device connection (it then appears on ThingsBoard)
publish v1/gateway/connect {"device": "bed-01"}
# Push telemetry for MANY sub-devices at once
publish v1/gateway/telemetry {"bed-01": [{"ts": 1750000000000, "values": {"heart_rate": 78, "spo2": 97.5}}]}
# Receive an RPC command from server for a sub-device
subscribe v1/gateway/rpc {"device":"bed-01", "data":{"id":1,"method":"setNurseCall","params":true}}
# Return the RPC result back to server
publish v1/gateway/rpc {"device":"bed-01","id":1,"data":{"success":true}}
```

### 4. Yêu cầu triển khai Docker (dùng chung)

• Toàn bộ hệ thống chạy được bằng một lệnh: docker compose up -d --build.
• Mỗi service tự lập trình phải có Dockerfile riêng.
• Cấu hình đọc từ environment variables, không hard-code trong source.
• Các service gọi nhau bằng service name (vd mosquitto, http://influxdb:8086), tuyệt đối không dùng localhost để gọi service khác.
• Dùng Docker volume cho InfluxDB và Grafana; khuyến khích volume/bind mount cho cấu hình Mosquitto.
• Các service giao tiếp qua một Docker Compose network chung.
Biến môi trường tối thiểu (đặt trong .env, không commit token thật):

```env
MQTT_BROKER=mosquitto
MQTT_PORT=1883
PUBLISH_INTERVAL=2
INFLUXDB_URL=http://influxdb:8086
INFLUXDB_TOKEN=...
INFLUXDB_ORG=hust
TB_HOST=thingsboard.cloud
TB_PORT=1883
INFLUXDB_BUCKET=iot
TB_GATEWAY_TOKEN=...
```

### 5. Cấu trúc thư mục gợi ý (dùng chung)

![[CleanShot 2026-06-16 at 10.53.38@2x.png]]

### Yêu cầu báo cáo, README và demo (dùng chung)

Mỗi nhóm nộp source code, docker-compose.yml, các Dockerfile, README.md, báo cáo PDF khoảng 15–20 trang và ảnh chụp màn hình. Báo cáo trình bày: kiến trúc, thiết kế topic/message, logic xử lý, rule engine,

tích hợp ThingsBoard (uplink + RPC), triển khai Docker Compose, dashboard Grafana và ThingsBoard, phân công công việc.

README.md phải đủ để người khác chạy lại: mô tả hệ thống, sơ đồ luồng dữ liệu, danh sách service, cách chạy, cách xem log, cách truy cập Grafana/InfluxDB/ ThingsBoard/REST API, cách gửi lệnh thủ công và các lỗi thường gặp. Các lệnh tối thiểu: docker compose up -d --build, docker compose ps, docker compose logs -f iot-gateway, docker compose down.

Khi demo, nhóm phải chứng minh: (1) chạy toàn bộ stack bằng Docker Compose; (2) nhiều virtual sensor đang publish; (3) gateway nhận telemetry, normalize và phát hiện ít nhất một event bất thường; (4) gateway gửi command tự động tới actuator và actuator publish lại status; (5) dữ liệu vào InfluxDB; (6) Grafana hiển thị telemetry/event/status; (7) telemetry xuất hiện trên ThingsBoard; (8) gửi RPC từ ThingsBoard (hoặc REST API) xuống actuator thành công.

# Chi tiết đề tài Virtual Smart Water & Flood Early-Warning Gateway

Xây dựng hệ thống Virtual IoT Gateway giám sát nguồn nước và cảnh báo sớm ngập lụt, thu thập mực nước, lưu lượng, lượng mưa và chất lượng nước tại nhiều trạm, tự động điều khiển bơm tiêu úng, cửa xả và còi cảnh báo qua MQTT, đồng bộ hai chiều với ThingsBoard Cloud (telemetry + RPC).

Ngập lụt đô thị và lũ trên sông gây thiệt hại lớn; cảnh báo sớm vài phút cũng có giá trị. Hệ thống quan trắc đặt cảm biến tại nhiều trạm dọc sông/kênh tiêu để theo dõi mực nước, lưu lượng và lượng mưa. Một edge gateway tại trạm có thể phát hiện mực nước vượt ngưỡng và lập tức kích hoạt bơm, mở cửa xả, hú còi mà không phụ thuộc đường truyền lên trung tâm; đồng thời đẩy dữ liệu lên ThingsBoard để trung tâm điều hành theo dõi toàn lưu vực và ra lệnh từ xa.

Mini-project yêu cầu giả lập toàn bộ cảm biến, thiết bị chấp hành và gateway bằng Python trong container Docker, triển khai bằng Docker Compose.

## Mục tiêu của mini-project

1. Lập trình nhiều virtual sensor mô phỏng các trạm quan trắc khác nhau.

2. Xây dựng edge gateway nhận telemetry MQTT từ nhiều trạm.

3. Thiết kế topic hierarchy và message format cho quan trắc nước.

4. Chuẩn hóa dữ liệu (mực nước, lưu lượng, lượng mưa, chất lượng nước).

5. Phát hiện cảnh báo nhiều mức (advisory/warning/emergency) bằng rule engine.

6. Tự động điều khiển bơm, cửa xả, còi và bảng cảnh báo qua MQTT.

7. Lưu telemetry, event và trạng thái actuator vào InfluxDB.

8. Tích hợp ThingsBoard: đẩy telemetry nhiều trạm và nhận RPC điều khiển từ xa.

9. Dashboard giám sát trên Grafana (edge) và ThingsBoard (cloud).

10. Cung cấp REST API truy vấn trạng thái trạm và điều khiển thủ công.

11. Container hóa và triển khai bằng Docker Compose.

## Mô tả bài toán

Hệ thống mô phỏng một lưu vực gồm tối thiểu 3 trạm: station-01, station-02, station-03. Mỗi trạm có:

• Một virtual sensor node gửi định kỳ: mực nước (m), lưu lượng (m 3 /s), lượng mưa (mm/h), độ đục (NTU), pH.

• Một virtual actuator node: bơm tiêu úng (pump), cửa xả/van (gate), còi cảnh báo (siren), bảng cảnh báo (board: hiển thị advisory/warning/emergency).

Edge gateway nhận dữ liệu, phát hiện nguy cơ ngập và điều khiển thiết bị tương ứng.

![[CleanShot 2026-06-16 at 10.57.56@2x.png]]

• mosquitto — MQTT broker.

• sensor-station-01/02/03 — sensor mỗi trạm.

• actuator-station-01/02/03 — actuator mỗi trạm.

• flood-gateway — edge IoT gateway.

• influxdb — time-series database.

• grafana — dashboard edge.

• flood-api — REST API (FastAPI).

Phải đủ các nhóm chức năng: sensor simulator, actuator simulator, broker, gateway, database, dashboard, API.

Phải đủ các nhóm chức năng: sensor simulator, actuator simulator, broker, gateway, database, dashboard, API.

### Thiết kế MQTT topic

```
basin/station-01/sensor/telemetry basin/station-01/actuator/command basin/station-01/actuator/status basin/station-01/gateway/normalized basin/station-01/gateway/event
```

### Message format yêu cầu

Telemetry từ sensor:

```json
{
  "device_id": "sensor-station-01",
  "basin_id": "to-lich",
  "station_id": "station-01",
  "water_level": 3.42,
  "flow_rate": 12.7,
  "rainfall": 45.0,
  "turbidity": 120.0,
  "ph": 7.1,
  "timestamp": "2026-06-10T10:00:00Z"
}
```

Command từ gateway tới actuator (target ∈ {pump, gate, siren, board}):

```json
{
  "station_id": "station-01",
  "target": "pump",
  "action": "on",
  "reason": "water_level_high",
  "timestamp": "2026-06-10T10:00:05Z"
}
```

Status từ actuator:

```json
{
  "device_id": "actuator-station-01",
  "station_id": "station-01",

  "pump": "on",
  "gate": "open",
  "siren": "off",
  "board": "warning",
  "last_command_reason": "water_level_high",
  "timestamp": "2026-06-10T10:00:06Z"
}
```

Event từ gateway:

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

### Yêu cầu lập trình

#### Virtual sensor

1. Đọc env: BASIN_ID, STATION_ID, DEVICE_ID, MQTT_BROKER, PUBLISH_INTERVAL.

2. Mô phỏng mực nước biến đổi theo lượng mưa (mưa lớn → mực nước dâng dần), lưu giá trị trước và thay đổi có xu hướng, không random độc lập.

3. Sinh tình huống: mưa to kéo dài, mực nước vượt ngưỡng, nước đục/pH bất thường.

4. Publish JSON lên basin/<station>/sensor/telemetry.

#### Virtual actuator

1. Subscribe topic command của trạm; parse JSON.

2. Cập nhật trạng thái pump, gate, siren, board.

3. Publish lại trạng thái lên topic status; ghi log.

#### Edge IoT gateway

1. Subscribe telemetry tất cả trạm; validate và normalize; tính tốc độ dâng mực nước (so với giá trị trước).

2. Lưu trạng thái mới nhất từng trạm; ghi telemetry vào InfluxDB.

3. Chạy rule engine; sinh và publish event; gửi command tới actuator.

4. Đẩy telemetry lên ThingsBoard và nhận RPC (mục 3.10).

#### Rule engine

Tối thiểu 4 luật (phân mức advisory/warning/emergency):

1. water_level > 3.0 ⇒ pump=on, gate=open, board=warning; event flood_warning, severity warning.

2. water_level > 4.0 ⇒ thêm siren=on, board=emergency; event flood_emergency, severity emergency.

3. rainfall > 40 và mực nước đang dâng ⇒ board=advisory; event heavy_rain, severity advisory.

4. turbidity > 100 hoặc ph < 6 / ph > 9 ⇒ event water_quality_alert, severity warning.

5. (Mở rộng) thời gian chạy bơm vượt ngưỡng ⇒ pump_maintenance; sensor offline ⇒ sensor_offline.

#### REST API

```
GET /health GET /stations/{station_id}/state POST /stations/{station_id}/command
GET /stations GET /stations/{station_id}/events
```

### Tích hợp ThingsBoard (uplink + RPC)

1. Tạo thiết bị Gateway, đặt token vào TB_GATEWAY_TOKEN; connect mỗi trạm rồi đẩy telemetry:

```json
// publish -> v1/gateway/telemetry
{
  "station-01": [
    {
      "ts": 1750000000000,
      "values": { "water_level": 4.2, "rainfall": 60, "flow_rate": 18.3 }
    }
  ],
  "station-02": [
    {
      "ts": 1750000000000,
      "values": { "water_level": 2.1, "rainfall": 15, "flow_rate": 7.0 }
    }
  ]
}
```

2. Nhận RPC để điều khiển bơm/cửa xả/còi từ trung tâm điều hành:

```json
// receive <- v1/gateway/rpc
{ "device":"station-01", "data":{"id":5,"method":"setPump","params":true} }
// reply -> v1/gateway/rpc :
{"device":"station-01","id":5,"data":{"success":true}}
```

3. Trên ThingsBoard: dashboard mực nước theo thời gian, bản đồ trạm, mức cảnh báo; nút RPC setPump/setGate/setSiren; Alarm nhiều mức theo ngưỡng mực nước (warning/emergency) cấu hình bằng Rule Chain.

#### Yêu cầu lưu trữ InfluxDB

• water_telemetry — tag: basin_id, station_id; field: water_level, flow_rate, rainfall, turbidity, ph.

• gateway_events — tag: station_id, event_type, severity; field: value, threshold.

• actuator_status — tag: station_id; field: pump, gate, siren, board.

#### Yêu cầu Grafana Dashboard

1. Mực nước theo thời gian cho từng trạm (kèm đường ngưỡng cảnh báo).

2. Lượng mưa theo thời gian cho từng trạm.

3. Lưu lượng và chất lượng nước (turbidity, pH).

4. Trạng thái bơm/cửa xả/còi/bảng cảnh báo theo trạm.

5. Số event theo mức (advisory/warning/emergency) theo thời gian.

6. Bảng event gần nhất: station_id, event_type, severity, action_taken.

### Docker và ảo hóa

Tuân thủ mục 4–5 Khung yêu cầu chung: mỗi service tự lập trình có Dockerfile riêng; volume cho InfluxDB/Grafana; cấu hình qua .env; service gọi nhau bằng tên.

### Câu hỏi bắt buộc trong báo cáo

1. Vì sao cảnh báo lũ cần xử lý tại edge thay vì chờ xử lý trên cloud?

2. Nhóm thiết kế topic và message format cho quan trắc nước thế nào?

3. Rule engine phân mức cảnh báo (advisory/warning/emergency) ra sao?

4. Khi mực nước vượt ngưỡng, luồng telemetry → cảnh báo → điều khiển diễn ra thế nào?

5. Gateway đóng vai trò ThingsBoard Gateway như thế nào?

6. Vì sao đẩy dữ liệu lên cloud vẫn cần, dù đã xử lý tại edge?

7. Vì sao container không nên dùng localhost để gọi service khác?

8. Muốn mở rộng giám sát toàn thành phố trên ThingsBoard cần thay đổi gì?

### Phân công gợi ý cho nhóm 3 sinh viên

• SV1: virtual sensor, virtual actuator, thiết kế topic/message.

• SV2: edge gateway, rule engine, ghi InfluxDB.

• SV3: tích hợp ThingsBoard + dashboard + alarm, REST API, Docker Compose, Grafana, README.

#### Yêu cầu nâng cao (cộng điểm khuyến khích)

1. Dự báo xu hướng mực nước ngắn hạn từ tốc độ dâng.

2. Bản đồ trạm và mức cảnh báo theo màu trên ThingsBoard.

3. Shared Attributes để chỉnh ngưỡng cảnh báo từ xa.

4. Health check cho các service trong Compose.

5. Alarm + thông báo (email/Telegram) khi vào mức emergency.

6. Phát hiện sensor_offline và mất kết nối trạm.

7. Unit test cho rule engine.

8. Cơ chế reconnect khi mất kết nối MQTT/ThingsBoard.

#### Kết luận

Đề tài giúp sinh viên xây dựng hệ thống quan trắc nước và cảnh báo lũ ảo hóa, nhấn mạnh vai trò xử lý thời gian thực tại biên cho các tình huống khẩn cấp, kết hợp với giám sát toàn lưu vực trên ThingsBoard Cloud. Sinh viên vận dụng MQTT, rule engine nhiều mức, InfluxDB, Grafana, ThingsBoard Gateway API, RPC, REST API và Docker Compose.
