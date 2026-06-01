# CNN Accelerator — Vivado Block Design 매뉴얼 (Arty A7-100T)

환경: Vivado/Vitis 2024.1, Arty A7-100T (xc7a100t-csg324-1)

## 1. 프로젝트 + Block Design
- 새 프로젝트 생성 → part `xc7a100t-csg324-1`
- Flow Navigator → Create Block Design (예: `cnn_accelerator_system`)

## 2. MIG (DDR3) + 클럭 토폴로지  ★가장 실수 잦은 곳★
1. Window → Board → **DDR3 SDRAM** 드래그
2. 자동 생성된 외부 포트 `sys_clk_i`, `clk_ref_i` **삭제**
3. MIG 더블클릭 → 재구성:
   - System Clock = **No Buffer**
   - Reference Clock = **No Buffer**
   - "Select Additional Clocks" **체크 해제**
   - Pin Selection 페이지에서 **Validate** → Finish
4. 포트 생성: `CLK100MHZ` (In, Clock, 100MHz), `ck_rst` (In, Active Low)
5. IP Catalog → **Utility Buffer** 추가 → C Buf Type = **BUFG**
6. IP Catalog → **Clocking Wizard** 추가:
   - Input Clock Source = **No buffer**
   - Output: `clk_out1`=100MHz(시스템), `clk_out2`=200MHz(MIG ref)
   - Reset Type = **Active Low**
7. 결선:
   - `CLK100MHZ` → BUFG `BUFG_I`
   - BUFG `BUFG_O` → MIG `sys_clk_i` **그리고** clk_wiz `clk_in1` (분기)
   - clk_wiz `clk_out2` → MIG `clk_ref_i`
   - `ck_rst` → MIG `sys_rst` **그리고** clk_wiz `resetn`
   - MIG `aresetn`은 6단계에서 연결

## 3. MicroBlaze
1. **Classic MicroBlaze** 추가 (MicroBlaze V 아님)
2. Run Block Automation:
   - Local Memory **16KB**, Debug Only, Peripheral AXI **Enabled**
   - **Clock Connection = `/clk_wiz_0/clk_out1`** (외부 CLK100MHZ 직결 금지)
3. V 변환 제안 뜨면 **Keep Classic MicroBlaze**
4. MicroBlaze 더블클릭 → Cache:
   - I-cache **16KB** / D-cache **32KB**, **Line Length 8**, **Victims 8**

## 4. UART
- **Board 탭 → USB UART** 드래그 (포트+핀 제약 자동) 권장
- IP Catalog로 추가 시 UART 인터페이스를 board usb_uart에 꼭 연결
- ⚠️ AXI Uartlite baud는 **합성 시 고정** (런타임 변경 불가). 기본 9600.
  115200 원하면 IP에서 변경 후 bitstream 재생성 필요.

## 5. Interconnect 2개 (반드시 **AXI Interconnect**, SmartConnect 아님 — DDR 성능)
- **ram_interconnect** (Slave 2 / Master 1):
  - MicroBlaze `M_AXI_IC` → S00, `M_AXI_DC` → S01, M00 → MIG `S_AXI`
- **perif_interconnect** (Slave 1 / Master N):
  - MicroBlaze `M_AXI_DP` → S00, M00 → UART `S_AXI`

## 6. Connection Automation
1. **데이터(S_AXI)는 5단계처럼 수동 결선** (자동화에 맡기면 SmartConnect 끼어듦)
2. Run Connection Automation → All (이때는 **클럭/리셋만** 뜸)
3. **수동**: MIG `aresetn` → ram_interconnect `M00_ARESETN`

## 7. 주소 할당
- Window → Address Editor → **Assign All**
- 결과: DDR `0x8000_0000`(256M), UART `0x4060_0000`(64K), LMB `0x0`(16K)
- DDR이 Instruction/Data 양쪽에 매핑돼야 캐시 경고 사라짐
- F6 (Validate) → critical warning 0개 확인

## 8. 마무리
- Sources → BD 우클릭 → Create HDL Wrapper ("Let Vivado manage")
- Generate Bitstream
- File → Export → Export Hardware → **Include Bitstream** → `.xsa`

## 9. Vitis
- `.xsa`로 Platform 생성 (standalone, `microblaze_0`)
- Application 생성 → 빌드 → Launch on Hardware
- Serial Terminal **baud = Uartlite와 일치** (현재 9600)
- 링커: 코드/데이터는 DDR(`0x8000_0000`)에 배치됨 (LMB는 16K라 작음)

## ⚠️ 알려진 미해결 (검증 중)
- DDR에서 코드 실행 시 **instruction fetch hang** 발생 가능
  → MIG AXI(ui_clk ~81.25MHz 도메인) 클럭/리셋 점검 필요:
    Proc Sys Reset 2개 존재 / ram M00_ACLK=ui_clk / M00_ARESETN=ui_clk reset
- UART baud 9600 ↔ 터미널 일치 (또는 IP를 115200으로 통일)