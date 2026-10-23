# Anti-tamper & Pro gate — BetterDisplay 3.5.6 (build 40870, arm64)

Case study: app tự bảo vệ thế nào, **gate Pro thật nằm ở đâu**, và cách vô hiệu hoá
bằng loader-dylib. Mọi số liệu đều đo trên máy thật: Accessibility tree,
`sample`, lldb, log của loader.

> Offset chỉ đúng cho **build 40870 / arm64**, VM base `0x100000000`.
> Build khác phải định vị lại bằng API xref / byte signature.

---

## 0. TL;DR

| Lớp | Có thật trong app? | Có phải gate Pro? |
|---|---|---|
| Self code-signature check (`Sec*`) | Có (import + code) | **Không** — runtime không hề gọi |
| Anti-debug (`sysctl`, `getppid`, `task_info`) | Có, chặn launch dưới debugger | Không |
| Anti-injection (dyld image monitor) | Có, Frida bị kill ngay | Không, nhưng chặn cách nạp |
| Obfuscation (hằng số mã hoá trong `__const`) | Có | Không |
| **Return value của `FUN_10043436c`** | Có, 385 call site | **ĐÚNG — đây là gate** |
| Beachball (sleep trên main thread) | Có, **cả ở bản gốc ký thật** | Không liên quan tamper |

Kết luận ngắn: licence Paddle chỉ là lớp UI. Thứ quyết định Pro là **một hàm so
sánh chuỗi nội bộ**, và chỉ cần trả `1` cho đúng 4 toán hạng của nó là mở toàn bộ
tính năng — không cần key, không cần server.

---

## 1. Bề mặt phòng thủ

### 1.1 Self code-signature check

App import và có code gọi:

```
SecStaticCodeCreateWithPath            # tạo static code object từ bundle
SecCodeCopySigningInformation          # đọc TeamIdentifier, cert chain
SecStaticCodeCheckValidityWithErrors   # verify theo designated requirement
```

Mục tiêu là xác nhận app được ký bằng Developer ID thật:

- Team ID kỳ vọng: `299YSU96J7`
- Requirement: `anchor apple generic and identifier "pro.betterdisplay.BetterDisplay"
  and certificate leaf[subject.OU] = "299YSU96J7"`

Điểm đáng chú ý: `TeamIdentifier` chỉ được gán khi cert do **Apple cấp**. Cert
self-signed dù set OU trùng cũng vẫn ra `TeamIdentifier = not set` → **không thể
giả** bằng cách tự ký.

**Nhưng:** hook cả 3 API + đặt breakpoint, rồi đi qua launch → activate → menu →
Settings trong 25 giây: **0 lần gọi**. Check này tồn tại nhưng không tham gia
quyết định Pro ở runtime.

### 1.2 Anti-debug

Import: `getppid`, `sysctl` / `sysctlbyname` / `sysctlnametomib` (cờ `P_TRACED`),
`task_info`, `_dyld_get_image_header`, `_dyld_image_count`,
`_dyld_register_func_for_add_image`.

Quan sát thực tế:

- **Launch dưới lldb** → app né nhánh check, hành vi khác bình thường.
- **Attach sau khi app đã chạy** → được, dùng đọc backtrace/bộ nhớ.

⇒ Khi cần trace, attach muộn thay vì launch dưới debugger.

### 1.3 Anti-injection

Frida 17.24 attach vào app đang chạy → **app tự kill ngay**. Khớp với việc app
theo dõi danh sách image nạp vào (`_dyld_*`): thấy dylib lạ xuất hiện sau launch
là phản ứng.

Phân biệt:

| Cách nạp | Kết quả |
|---|---|
| `DYLD_INSERT_LIBRARIES` / Frida task-inject | **Bị kill** |
| lldb attach (không nạp code) | Được |
| **Dylib khai báo sẵn trong load command** | **Không bị phát hiện** |

Đây là lý do kỹ thuật delivery ở §3.1 quan trọng ngang bản thân patch.

### 1.4 Obfuscation

Giá trị kỳ vọng (Team ID, requirement, hằng licence) không nằm dạng chuỗi ASCII
mà **mã hoá** trong `__const` (~`0x98c000`), giải mã lúc chạy:

- Vòng xử lý `Data` đọc/ghi từng byte hàng trăm lần.
- Gọi `swift_stdlib_random` (nonce / jitter).
- Khối hằng entropy cao, không grep được `299YSU96J7` hay requirement.

⇒ Không thể tìm gate bằng `strings`; phải decompile hoặc log runtime.

---

## 2. Gate Pro thật

### 2.1 Licence Paddle không quyết định

Trạng thái Paddle đọc trực tiếp từ `PADProduct` khi app đang chạy:

```
activated          = 1
canActivate        = 1
licenseCode        = BETTER-DISPLAY-KEYGEN-0001
activationEmail    = panda@example.com
productType        = 1
trialDaysRemaining = -739913      # trialStartDate = 0001-01-01
```

Licence "hợp lệ" đầy đủ — **nhưng toàn bộ toggle Pro vẫn `AXEnabled = false`**.

Chiều ngược lại cũng đúng: khi gate đã bị hook, **tắt hẳn licence server** rồi
relaunch → 16/16 toggle vẫn bật. Licence chỉ ảnh hưởng dòng trạng thái trong
Settings, không điều khiển tính năng.

### 2.2 Gate = return value của `FUN_10043436c`

Ghidra decompile cho thấy đây là helper so sánh chuỗi kiểu Swift:

- Đọc tag 2 bit cao của `_countAndFlags` (`lsr #62`) để phân biệt small string.
- Tính count của 2 chuỗi, so count, rồi so nội dung.
- Trả `1` / `0`.
- **385 call site** trong app.

Bằng chứng nó là gate: patch entry thành `mov w0,#1 ; ret` → **cả 16 toggle Pro
bật** (`AXEnabled = true`). Không có thay đổi nào khác.

Nhưng patch cứng như vậy phá mọi so sánh chuỗi khác → phải làm **chọn lọc**.

### 2.3 Toán hạng quyết định

Hook hàm trên bằng một dispatcher có log `x2` (word `_object` của String thứ 2).
Các lần gọi mang giá trị licence:

| `x2` | Số lần | Vai trò |
|---|---|---|
| `0xb41e88f80d1370eb` | 28 | so sánh licence |
| `0x3000000000` | 19 | **quyết định verdict** |
| `0xbbc3ac02004f5a23` | 12 | so sánh licence |
| `0xc80bc8766576e5b0` | 2 | so sánh licence |

Đo thực nghiệm: ép 3 giá trị đầu → **vẫn khoá**; ép thêm `0x3000000000` → **mở**.
Vậy trong 4 giá trị, `0x3000000000` là cái mang quyết định.

Các hằng này là **theo từng version** — build khác phải log lại, không dùng lại được.

---

## 3. Vô hiệu hoá

### 3.1 Delivery — nạp loader không kích anti-injection

```
Contents/Frameworks/libbdfree.dylib        # loader của mình
Sparkle.framework                          # bị thêm LC_LOAD_DYLIB
  └─ LC_LOAD_DYLIB @rpath/libbdfree.dylib
```

- `inject_dylib.py` ghi thêm load command vào Mach-O của **Sparkle** (cả 2 slice),
  tận dụng padding của header nên offset không đổi.
- App nạp Sparkle như bình thường → kéo theo `libbdfree` **ngay lúc launch**, trong
  tập image hợp lệ → anti-injection không thấy gì bất thường.
- Ký lại ad-hoc, **không** `--options runtime` (xem §5).

### 3.2 Inline hook: dispatcher + trampoline

Constructor của dylib chạy trước code app, cài hook tại `0x10043436c`:

```
target+0x00      : b  near_page                     ; ghi đè đúng 4 byte
near_page+0x00   : ldr x16,#8 ; br x16 ; .quad bd_cmp_dispatch
near_page+0x10   : <instruction gốc> ; ldr x16,#8 ; br x16 ; .quad target+4
```

Dispatcher (`loader/hook.S`):

```
cmp x2, #0xb41e88f80d1370eb -> w0 = 1 ; ret
cmp x2, #0xbbc3ac02004f5a23 -> w0 = 1 ; ret
cmp x2, #0xc80bc8766576e5b0 -> w0 = 1 ; ret
cmp x2, #0x3000000000       -> w0 = 1 ; ret
else -> br trampoline       ; chạy tiếp hàm gốc, không đổi hành vi
```

Điểm cần chú ý:

- Page phải nằm trong **±128 MiB** của target, nếu không branch tương đối không với
  tới. Cách làm: thử `mach_vm_allocate(VM_FLAGS_FIXED)` ở `target + 16MB`, `+32MB`…
  đến khi được.
- Trampoline replay **đúng 1 instruction** rồi nhảy về `target+4`.
- Trước khi ghi: `mach_vm_protect(RW | VM_PROT_COPY)`, sau khi ghi trả lại `RX`.

### 3.3 Vì sao chỉ patch 4 byte

16 byte đầu của hàm:

```
d37efc29   lsr  x9, x1, #62
7100053f   cmp  w9, #1
5400008c   b.gt ...
35000149   cbnz ...
```

Có **2 branch PC-relative**. Copy 16 byte sang page khác mà không relocate → nhảy
sai địa chỉ → **SIGILL**. Relocate thì phức tạp và vẫn có thể lệch.

Chỉ ghi 4 byte (1 instruction) thì không có gì PC-relative để relocate → an toàn
và tối thiểu.

---

## 4. Beachball — vấn đề riêng, không phải anti-tamper

Đây là điểm dễ kết luận sai nhất:

- `sample` trên **bản gốc ký Developer ID thật** cũng cho ra đúng vòng sleep đó
  (~86% mẫu nằm trong `+[NSThread sleepForTimeInterval:]` trên main thread).
- Nghĩa là beachball là **behaviour của 3.5.6 trên máy này**, không phải hình phạt
  do bị patch. Không được dùng nó làm thước đo "đã bị phát hiện".

Cách xử lý (độc lập với gate): swizzle
`+[NSThread sleepForTimeInterval:]`, chỉ bỏ qua khi `[NSThread isMainThread]`,
còn lại gọi bản gốc. Menu bung tức thì, sleep nền vẫn chạy bình thường.

---

## 5. Những hướng đã thử và thất bại

| Cách | Kết quả |
|---|---|
| `fishhook` rebind `Sec*` | Không bao giờ fire — binary dùng **chained fixups**, rebind trượt |
| DYLD interposing | Không redirect được main executable (bind trước) |
| Vá data slot của các hằng | Không phải cơ chế; đã revert |
| Swizzle `PADProduct` (`activated`, `licenseCode`, `trialDaysRemaining`) | **SIGSEGV** (`objc_retain` trong block khởi động) |
| KVC `AppCore`, set defaults `showProControls` / `allowLicensing` | Không đổi gì — đây là `@AppStorage` object, không phải cờ |
| Patch cứng hàm so sánh → luôn `1` | Mở Pro nhưng phá 385 call site → không dùng được |
| Patch 16 byte + relocate prologue | **SIGILL** |
| Trampoline đặt quá xa target | Branch ngoài tầm ±128 MiB |
| Ký `--options runtime` | Ghi `__TEXT` → **SIGKILL (Code Signature Invalid)** |

Hai điểm kỹ thuật đáng nhớ:

- **Chained fixups làm fishhook vô dụng.** Cách thật sự hiệu quả: vá thẳng 2 slot
  8-byte trong `__DATA_CONST` (`0x100b0f648`, `0x100b0f650`) và stub
  `0x100960404` cho call site trực tiếp.
- **Hardened runtime phải tắt.** Không có nó thì `mach_vm_protect` + ghi
  `__TEXT` mới sống.

---

## 6. Kiểm chứng

Đo bằng Accessibility tree (`AXEnabled`), không dựa vào ảnh chụp:

| Hạng mục | Trước | Sau |
|---|---|---|
| Toggle bị disable trong Settings | 2 | **0** (tổng 16) |
| `Dim display brightness on screen saver or lock` | `false` | **`true`** |
| `Enable flexible scaling` | `false` | **`true`** |
| Native / software XDR rows | `false` | **`true`** |
| Pro khi tắt licence server | — | **16/16 vẫn bật** |
| Nút nguồn ⏻ trên menu bar | không tác dụng | **tắt/bật được màn hình** |
| Stability | — | không crash sau build cuối |

---

## 7. Offset tham chiếu

| Địa chỉ VM | Ý nghĩa |
|---|---|
| `0x10043436c` | **Gate Pro** — helper so sánh chuỗi, 385 call site |
| `0x100b0f648` | slot `_SecCodeCopySigningInformation` (`__DATA_CONST`) |
| `0x100b0f650` | slot `_SecStaticCodeCheckValidityWithErrors` (`__DATA_CONST`) |
| `0x100960404` | `__stubs` cho `SecCodeCopySigningInformation` |
| `0x2b1464` / `0x2b15b0` | `SecStaticCodeCreateWithPath` / `SecCodeCopySigningInformation` (call site) |
| `0x3b5d60` / `0x3b5f5c` / `0x3b7ad4` | check chữ ký thứ 2 (create + info + validity) |
| `0x3b7b3c` | `cmp` + `b.ne` trên kết quả `SecStaticCodeCheckValidityWithErrors` |
| `~0x98c000` | `__const` chứa hằng số đã mã hoá |

---

## 8. Bài học tổng quát

1. **Licence UI ≠ gate.** Trạng thái "Pro is Active" có thể chỉ là text. Kiểm tra
   bằng cách đo `AXEnabled` của control Pro, không đọc nhãn.
2. **Chứng minh gate bằng thực nghiệm.** Patch ứng viên thành hằng số rồi quan sát
   hành vi; đừng suy luận từ tên hàm hay chuỗi.
3. **Log toán hạng thay vì dò pattern.** Hằng số obfuscate theo từng version; hook
   rồi in register là cách nhanh nhất để lấy bộ giá trị đúng.
4. **Delivery quyết định.** Dylib khai báo sẵn trong framework phụ sống sót qua
   anti-injection; Frida/`DYLD_INSERT` thì không.
5. **Patch in-memory thắng patch tĩnh.** Không phải đối đầu trực tiếp với
   self-signature, và chạy trước khi logic bảo vệ kịp khởi động.
6. **Selectivity giữ app nguyên vẹn.** Dispatcher chỉ trả lời đúng vài toán hạng,
   phần còn lại trả về hàm gốc qua trampoline.
7. **Phân biệt bug với hình phạt.** Luôn `sample` bản gốc ký thật trước khi kết
   luận "app đang phạt mình".
8. **Hardened runtime và `__TEXT` không đi chung.** Muốn vá code trong RAM thì phải
   ký không `--options runtime`.

### Checklist khi gặp app khác

- `nm -u` → tìm `Sec*`, `sysctl`, `getppid`, `task_info`, `_dyld_*`, Sentry.
- `sample <pid>` → phát hiện sleep/loop bất thường trên main thread.
- Accessibility tree → đọc `AXEnabled` thật của control bị khoá.
- Ghidra/radare2 → decompile ứng viên, xác định convention trả về.
- Hook + log register → lấy bộ toán hạng quyết định.
- Viết dispatcher chọn lọc + trampoline → verify bằng `AXEnabled`.

---

## 9. Công cụ

| Công cụ | Dùng để |
|---|---|
| Ghidra 12.1.4 + JDK 21 | decompile (mac_arm_64 decompiler phải build từ source) |
| radare2 | `axt` xref, `pdf`/`pdc`, tìm call site |
| `otool -tV`, `nm -u` | disassemble tĩnh, liệt kê import |
| capstone | verify encoding trước khi ghi byte |
| `sample` | đo main-thread, không cần quyền debug |
| lldb **attach** | đọc runtime (launch thì bị anti-debug né) |
| `System Events` / AX API | đọc `AXEnabled`, `AXValue` của UI |
| REA (Ghidra provider) | tự động hoá vòng decompile |
