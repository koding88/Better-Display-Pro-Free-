# BetterDisplay Free 🎓

Biến **BetterDisplay 3.5.6** thành bản Pro — **activate bằng key bất kỳ**, chạy hoàn toàn offline với server license trên máy bạn. Dành cho mục đích **học tập / nghiên cứu** (reverse engineering, licensing client/server).

- ✅ Không cần key thật, không cần tài khoản Paddle
- ✅ Server license chạy local (`127.0.0.1:8543`), không cần internet
- ✅ App gốc `/Applications/BetterDisplay.app` **không bị đụng tới**
- ✅ Bản Free có settings riêng (bundle ID `pro.betterdisplay.BetterDisplay.free`); file license Paddle dùng chung với app gốc

---

## 📋 Yêu cầu

| Thứ | Chi tiết |
|---|---|
| macOS | Test trên macOS 13.2, Apple Silicon. Intel đã có patch nhưng chưa test |
| BetterDisplay | **Đúng 3.5.6 (build 40870)** — tải bản này trước, cài vào `/Applications` |
| Python 3 | Có sẵn trên macOS (`python3 --version`) |
| Quyền ghi | Ghi được vào `/Applications` (user admin). Nếu không, chạy `sudo bash patch_copy.sh` |

Kiểm tra version:

```bash
plutil -p "/Applications/BetterDisplay.app/Contents/Info.plist" \
  | grep -E "CFBundleShortVersionString|CFBundleVersion"
# Đúng: 3.5.6  và  40870
```

> ⚠️ Bản khác **không được hỗ trợ** — patch binary dựa trên offset của đúng build này.

---

## ⚡ Cài đặt (4 bước, ~2 phút)

### Bước 1 — Build bản Free

```bash
cd /đường/dẫn/tới/bdkeygen
bash patch_copy.sh
```

Script sẽ:

1. Backup license + prefs gốc vào `backup/<timestamp>/`
2. Copy `/Applications/BetterDisplay.app` → `/Applications/BetterDisplay Free.app`
3. Đổi bundle ID sang `pro.betterdisplay.BetterDisplay.free` (settings được copy sang domain mới)
4. Patch Paddle URL + `destroyActivation`
5. Ký ad-hoc bản copy

Kết quả đúng:

```
→ patching Paddle.framework
  Paddle base URL -> localhost: 2 occurrence(s)
  destroyActivation no-op: arch 0x1000007 @ +0xaf5f
  destroyActivation no-op: arch 0x100000c @ +0xb704
→ patching BetterDisplay executable
  activations URL -> localhost: 2 occurrence(s)
→ binary patches OK
OK — patched copy ready: /Applications/BetterDisplay Free.app
```

### Bước 2 — Chạy server + app

```bash
./keygen.command
```

Lệnh này bật server local ở `127.0.0.1:8543` rồi mở **BetterDisplay Free**.

Các lệnh khác:

```bash
./keygen.command status   # server/app đang chạy?
./keygen.command stop     # tắt server
```

### Bước 3 — Activate

Trong app: **menu bar → icon BetterDisplay → Activate License…**

Nhập:

| Field | Giá trị |
|---|---|
| Email | bất kỳ, ví dụ `panda@example.com` |
| License key | bất kỳ, ví dụ `BETTER-DISPLAY-KEYGEN-0001` |

→ bấm **Activate** → app báo **License Activated** / Pro.

### Bước 4 — Dùng

- App đã là Pro. Mở **BetterDisplay Free** từ Applications.
- Nếu server vẫn chạy, app verify thành công mỗi lần mở (không warning).
- Nếu server tắt, app vẫn giữ license (đã patch `destroyActivation`), nhưng có thể hiện cảnh báo license. Chạy `./keygen.command` rồi mở lại app để hết cảnh báo.

---

## 🚀 Sau khi cài

- **Không cần internet.** Server chỉ chạy local.
- **Đừng chạy app gốc** `/Applications/BetterDisplay.app` sau khi activate: bản gốc verify với Paddle thật và có thể xoá license dùng chung. Nếu không cần bản gốc nữa, xoá nó.
- **Đừng bấm Check For Updates** trong app — bản update mới sẽ không khớp patch. Lỡ update thì xoá bản Free, cài lại đúng 3.5.6, build lại.
- License lưu tại `~/Library/Application Support/BetterDisplay/762421.spadl` (dùng chung với app gốc — xem mục Gỡ cài đặt).

---

## 🔧 Nó hoạt động thế nào? (3 dòng)

1. Bản patch đổi URL license của Paddle từ `v3.paddleapi.com` về **server local** (`127.0.0.1:8543`).
2. Server local trả JSON license và **ký HMAC-SHA256** bằng đúng API key nhúng trong BetterDisplay — nên app tin response là thật.
3. `-[PADProduct destroyActivation]` bị patch thành no-op, để app không xoá license khi server tắt / verify offline thất bại.

---

## 🗂 Cấu trúc

| File | Việc |
|---|---|
| `patch_copy.sh` | Tạo `/Applications/BetterDisplay Free.app` từ bản gốc |
| `patch_binary.py` | Patch URL + `destroyActivation` (có check version/byte signature) |
| `bd_keygen_server.py` | Server license local `:8543`, ký response bằng API key của app |
| `keygen.command` | Bật server + mở app (`status` / `stop`) |
| `config.json` | Product/vendor/API key/port/activation id |
| `backup/` | License + prefs gốc được backup lúc build (không commit) |

---

## ❓ Xử lý sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| Activate báo *"Could not connect"* | Server chưa chạy: `./keygen.command status` → nếu stopped thì `./keygen.command` |
| `server failed to start` | Port 8543 bị chiếm: `lsof -nP -iTCP:8543 -sTCP:LISTEN`, tắt app/server đang dùng port rồi thử lại |
| Activate báo *"Activation failed"* | Sai version app, hoặc server trả response lỗi — xem `bd_keygen_server.log` |
| App vẫn trial / không Pro | Activate lại; kiểm tra `defaults read pro.betterdisplay.BetterDisplay.free \| grep Paddle` |
| App báo *License Issue Detected* | Server tắt hoặc verify fail — chạy `./keygen.command` rồi mở lại app |
| Có 2 icon BetterDisplay trên menu bar | App gốc vẫn đang chạy → quit app gốc, chỉ dùng bản Free |
| Muốn quay lại app gốc | Xoá bản Free, khôi phục file từ `backup/<timestamp>/` |

Log server: `bd_keygen_server.log` (cùng thư mục repo).

---

## 🗑 Gỡ cài đặt

```bash
./keygen.command stop
rm -rf "/Applications/BetterDisplay Free.app"
defaults delete pro.betterdisplay.BetterDisplay.free 2>/dev/null
rm -f "$HOME/Library/Application Support/BetterDisplay/762421.spadl"
```

- License file `762421.spadl` dùng chung với app gốc; xoá nó sẽ reset license của cả hai.
- Muốn khôi phục license/prefs gốc: copy lại từ `backup/<timestamp>/`.
- Sau khi hài lòng, có thể xoá thư mục `backup/`.

---

## ❓ FAQ

- **Key nào cũng được hả?** Đúng. Server local accept mọi key; app lưu key đó vào license file.
- **Cần internet không?** Không. Server chỉ ở `127.0.0.1`.
- **Sau khi build xoá app gốc được không?** Được. Giữ installer 3.5.6 để sau này build lại.
- **Cho bạn bè dùng được không?** Được — mỗi máy chạy `patch_copy.sh` + `keygen.command` và activate.
- **Dùng thấy ngon thì sao?** BetterDisplay là sản phẩm của **waydabber** — dùng lâu dài thì nên mua license ủng hộ dev 😉.

---

## ⚖️ Ghi chú

> Repo cho mục đích **học tập / nghiên cứu** (reverse engineering, licensing client/server, Mach-O patching). API key trong repo là key nhúng công khai trong app, chỉ dùng cho server local trên máy bạn. **BetterDisplay là sản phẩm của waydabber — hãy ủng hộ nhà phát triển nếu bạn thấy phần mềm hữu ích.**
