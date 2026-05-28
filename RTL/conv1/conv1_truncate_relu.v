`timescale 1ns / 1ps

module conv1_truncate_relu (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,

    input  wire signed [23:0] sum0,
    input  wire signed [23:0] sum1,
    input  wire signed [23:0] sum2,
    input  wire signed [23:0] sum3,

    output reg signed [7:0] out0,
    output reg signed [7:0] out1,
    output reg signed [7:0] out2,
    output reg signed [7:0] out3
);

    //==========================================================================
    // sat_relu 함수 (동일)
    //==========================================================================
    function signed [7:0] sat_relu;
        input signed [13:0] val;
        begin
            if (val > 14'sd127)
                sat_relu = 8'sd127;
            else if (val < 14'sd0)
                sat_relu = 8'sd0;    // ReLU: 음수 → 0
            else
                sat_relu = val[7:0];
        end
    endfunction

    //==========================================================================
    // [버그 수정] 시프트 상수를 명확하게 signed 포맷('sd10)으로 지정합니다.
    // 이렇게 해야 Unsigned로 오인되어 논리 시프트(0 채우기)가 일어나는 것을 막습니다.
    //==========================================================================
    wire signed [13:0] sh0 = sum0 >>> 14'sd10;
    wire signed [13:0] sh1 = sum1 >>> 14'sd10;
    wire signed [13:0] sh2 = sum2 >>> 14'sd10;
    wire signed [13:0] sh3 = sum3 >>> 14'sd10;

    //==========================================================================
    // 출력 레지스터 업데이트
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            out0 <= 8'sd0;
            out1 <= 8'sd0;
            out2 <= 8'sd0;
            out3 <= 8'sd0;
        end else if (en) begin 
            out0 <= sat_relu(sh0);
            out1 <= sat_relu(sh1);
            out2 <= sat_relu(sh2);
            out3 <= sat_relu(sh3);
        end
        // 만약 에러가 지속된다면 `else if (en)` 대신 항상 업데이트 하도록 
        // 테스트해볼 수 있으나, 타이밍 정렬을 위해 우선 en 조건 하에 올바른 값을 주입합니다.
    end

endmodule