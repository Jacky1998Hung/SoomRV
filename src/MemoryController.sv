module MemoryController
#(parameter NUM_CACHES=2, parameter NUM_TFS_IN=3, parameter ADDR_LEN=32, parameter WIDTH=`AXI_WIDTH)
(
    input wire clk,
    input wire rst,

    input MemController_Req IN_ctrl[NUM_TFS_IN-1:0],
    output MemController_Res OUT_stat,

    output ICacheIF OUT_icacheW,
    output CacheIF OUT_dcacheW,
    input logic IN_dcacheRReady,
    output CacheIF OUT_dcacheR,
    input wire[32*`CWIDTH-1:0] IN_dcacheR,

    output logic[`AXI_ID_LEN-1:0]  s_axi_awid, // write req id
    output logic[ADDR_LEN-1:0] s_axi_awaddr, // write addr
    output logic[7:0] s_axi_awlen, // write len
    output logic[2:0] s_axi_awsize, // word size
    output logic[1:0] s_axi_awburst, // FIXED, INCR, WRAP, RESERVED
    output logic[0:0] s_axi_awlock, // exclusive access
    output logic[3:0] s_axi_awcache, // {allocate, other allocate, modifiable, bufferable}
    output logic s_axi_awvalid,
    input logic s_axi_awready,

    // write stream
    output logic [WIDTH-1:0] s_axi_wdata,
    output logic [(WIDTH/8)-1:0] s_axi_wstrb,
    output logic s_axi_wlast,
    output logic s_axi_wvalid,
    input logic s_axi_wready,

    // write response
    output logic s_axi_bready,
    input logic[`AXI_ID_LEN-1:0] s_axi_bid,
    //input[1:0] s_axi_bresp,
    input logic s_axi_bvalid,

    // read request
    output logic[`AXI_ID_LEN-1:0] s_axi_arid,
    output logic[ADDR_LEN-1:0] s_axi_araddr,
    output logic[7:0] s_axi_arlen,
    output logic[2:0] s_axi_arsize,
    output logic[1:0] s_axi_arburst,
    output logic[0:0] s_axi_arlock,
    output logic[3:0] s_axi_arcache, // {other allocate, allocate, modifiable, bufferable}
    output logic s_axi_arvalid,
    input logic s_axi_arready,

    // read stream
    output logic s_axi_rready,
    input logic[`AXI_ID_LEN-1:0] s_axi_rid,
    input logic[WIDTH-1:0] s_axi_rdata,
    //input logic[1:0] s_axi_rresp,
    input logic s_axi_rlast,
    input logic s_axi_rvalid,

    output DebugInfoMemC OUT_dbg
);

localparam WIDTH_W_ = (WIDTH / 32);
localparam WIDTH_W = WIDTH_W_[`CLSIZE_E-2:0];


typedef enum logic[1:0]
{
    FIXED, INCR, WRAP
} BurstType;

typedef struct packed
{
    // On store cache misses, we allow fusing a single
    // store into the cache line read
    logic[`AXI_WIDTH-1:0] storeData;
    logic[(`AXI_WIDTH/8)-1:0] storeMask;


    logic[`CLSIZE_E-2:0] evictProgress;
    logic[`CLSIZE_E-2:0] progress;
    logic[`CLSIZE_E-2:0] addrCounter;
    logic[`CLSIZE_E-2:0] fwdAddrCounter;
    logic[`CACHE_SIZE_E-3:0] cacheAddr;
    logic[31:0] readAddr;
    logic[31:0] writeAddr;

    // r/w from AXI perspective
    logic needReadRq;
    logic[1:0] needWriteRq; // 0: cache, 1: AXI

    logic readDone;
    logic writeDone;

    CacheID_t cacheID;
    MemC_Cmd cmd;
    logic valid;
} Transfer /* public */;

Transfer transfers[`AXI_NUM_TRANS-1:0];

logic[`AXI_NUM_TRANS-1:0] isMMIO;
always_comb begin
    for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
        case(transfers[i].cmd)
            MEMC_READ_BYTE, MEMC_READ_HALF, MEMC_READ_WORD,
            MEMC_WRITE_BYTE, MEMC_WRITE_HALF, MEMC_WRITE_WORD:
                isMMIO[i] = transfers[i].valid;
            default:
                isMMIO[i] = 0;
        endcase
    end
end

MemController_SglLdRes sglLdRes;
MemController_SglStRes sglStRes;
MemController_LdDataFwd ldDataFwd;

// Find enqueue index
logic[$clog2(`AXI_NUM_TRANS)-1:0] enqIdx;
logic enqIdxValid;
always_comb begin
    enqIdx = 'x;
    enqIdxValid = 0;
    for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
        if (!enqIdxValid && !transfers[i].valid) begin
            enqIdx = i[$clog2(`AXI_NUM_TRANS)-1:0];
            enqIdxValid = 1;
        end
    end
end

function logic IsCacheOp(MemC_Cmd cmd);
    return cmd == MEMC_REPLACE || cmd == MEMC_CP_CACHE_TO_EXT || cmd == MEMC_CP_EXT_TO_CACHE;
endfunction

// Select Incoming Transfer
MemController_Req selReq;
always_comb begin
    reg cacheAddrColl = 'x;
    OUT_stat.stall = {NUM_TFS_IN{1'b1}};
    selReq = 'x;
    selReq.cmd = MEMC_NONE;

    if (enqIdxValid) begin
        for (integer i = 0; i < NUM_TFS_IN; i=i+1) begin
            if (selReq.cmd == MEMC_NONE && IN_ctrl[i].cmd != MEMC_NONE) begin
                cacheAddrColl = 0;
                for (integer j = 0; j < `AXI_NUM_TRANS; j=j+1)
                    cacheAddrColl |=
                        transfers[j].valid &&
                        IsCacheOp(IN_ctrl[i].cmd) &&
                        IsCacheOp(transfers[j].cmd) &&
                        IN_ctrl[i].cacheID == transfers[j].cacheID &&
                        IN_ctrl[i].cacheAddr[`CACHE_SIZE_E-3:`CLSIZE_E-2] == transfers[j].cacheAddr[`CACHE_SIZE_E-3:`CLSIZE_E-2];
                if (!cacheAddrColl) begin
                    selReq = IN_ctrl[i];
                    OUT_stat.stall = ~(1 << i);
                end
            end
        end
    end
end

// AXI read control signals
typedef struct packed
{
    logic[`AXI_ID_LEN-1:0] arid;
    logic[ADDR_LEN-1:0] araddr;
    logic[7:0] arlen;
    logic[2:0] arsize;
    logic[1:0] arburst;
    logic[0:0] arlock;
    logic[3:0] arcache;
    logic arvalid;
} AXI_AR;
AXI_AR axiAR;
logic arFIFO_outValid;
logic arFIFO_ready;
assign s_axi_arvalid = arFIFO_outValid;
FIFO#($bits(AXI_AR)-1, 2, 1, 0) arFIFO
(
    .clk(clk),
    .rst(rst),
    .free(),

    .IN_valid(axiAR.arvalid),
    .IN_data(axiAR[1+:$bits(AXI_AR)-1]),
    .OUT_ready(arFIFO_ready),

    .OUT_valid(arFIFO_outValid),
    .IN_ready(s_axi_arready),
    .OUT_data({s_axi_arid, s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst, s_axi_arlock, s_axi_arcache})
);
reg[$clog2(`AXI_NUM_TRANS)-1:0] arIdx;
reg arIdxValid;
wire readReqSuccess = axiAR.arvalid && arFIFO_ready;
always_comb begin

    axiAR = 'x;
    axiAR.arvalid = 0;

    // Find Op that requires read request
    arIdx = 'x;
    arIdxValid = 0;
    for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
        if (!arIdxValid && transfers[i].valid && transfers[i].needReadRq) begin
            arIdx = i[$clog2(`AXI_NUM_TRANS)-1:0];
            arIdxValid = 1;
        end
    end

    // Reads only have to be requested on AXI. The MemoryWriteInterface
    // handles data as it comes in, no setup required.
    if (arIdxValid) begin
        axiAR.arvalid = 1;
        axiAR.arburst = isMMIO[arIdx] ? FIXED : WRAP;
        axiAR.arlen = isMMIO[arIdx] ? 0 : ((1 << (`CLSIZE_E - $clog2(WIDTH / 8))) - 1);
        axiAR.araddr = transfers[arIdx].readAddr;
        axiAR.arid = arIdx;

        case (transfers[arIdx].cmd)
            MEMC_READ_BYTE: axiAR.arsize = 0;
            MEMC_READ_HALF: axiAR.arsize = 1;
            MEMC_READ_WORD: axiAR.arsize = 2;
            default: axiAR.arsize = 3'($clog2(WIDTH/8));
        endcase
    end
end

// Output status to clients
always_comb begin
    OUT_stat.busy = 1; // make old clients stall

    // Cache Line Transfer Status
    for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
        OUT_stat.transfers[i] = 'x;
        OUT_stat.transfers[i].valid = 0;

        if (transfers[i].valid && !isMMIO[i]) begin
            OUT_stat.transfers[i].valid = 1;
            OUT_stat.transfers[i].cacheID = transfers[i].cacheID;
            OUT_stat.transfers[i].progress = transfers[i].progress[`CLSIZE_E-2:0];
            OUT_stat.transfers[i].cacheAddr = transfers[i].cacheAddr;
            OUT_stat.transfers[i].writeAddr = transfers[i].writeAddr;
            OUT_stat.transfers[i].readAddr = transfers[i].readAddr;

            OUT_stat.transfers[i].active =
                (transfers[i].needReadRq == 0) &&
                (transfers[i].needWriteRq == 0) &&
                (transfers[i].evictProgress != 0);
        end
    end

    OUT_stat.ldDataFwd = ldDataFwd;

    // MMIO
    OUT_stat.sglLdRes = sglLdRes;
    OUT_stat.sglStRes = sglStRes;

end

// Output Debug Info
always_comb begin
    for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
        OUT_dbg.transfValid[i] = transfers[i].valid;
        OUT_dbg.transfReadDone[i] = transfers[i].progress[`CLSIZE_E-2];
        OUT_dbg.transfWriteDone[i] = transfers[i].evictProgress[`CLSIZE_E-2];
        OUT_dbg.transfIsMMIO[i] = isMMIO[i];
    end
end

logic ICW_ready;
logic ICW_valid;
logic[`CACHE_SIZE_E-3:0] ICW_addr;
logic[WIDTH-1:0] ICW_data;
logic[`AXI_ID_LEN-1:0] ICW_id;

logic ICW_ackValid;
logic[`AXI_ID_LEN-1:0] ICW_ackId;

CacheWriteInterface#(`CACHE_SIZE_E-2, 8, WIDTH, 8 << `FSIZE_E, `AXI_ID_LEN) icacheWriteIF
(
    .clk(clk),
    .rst(rst),

    .OUT_ready(ICW_ready),
    .IN_valid(ICW_valid),
    .IN_addr(ICW_addr),
    .IN_data(ICW_data),
    .IN_id(ICW_id),

    .OUT_ackValid(ICW_ackValid),
    .OUT_ackId(ICW_ackId),

    .IN_CACHE_ready(1'b1),
    .OUT_CACHE_ce(OUT_icacheW.ce),
    .OUT_CACHE_we(OUT_icacheW.we),
    .OUT_CACHE_wm(OUT_icacheW.wm),
    .OUT_CACHE_addr(OUT_icacheW.addr),
    .OUT_CACHE_data(OUT_icacheW.data)
);

logic DCW_ready;
logic DCW_valid;
logic[`CACHE_SIZE_E-3:0] DCW_addr;
logic[WIDTH-1:0] DCW_data;
logic[`AXI_ID_LEN-1:0] DCW_id;

logic DCW_ackValid;
logic[`AXI_ID_LEN-1:0] DCW_ackId;


logic DCW_CACHE_ready;
logic DCW_CACHE_ce;
logic DCW_CACHE_we;
logic[`CACHE_SIZE_E-3:0] DCW_CACHE_addr;
CacheWriteInterface#(`CACHE_SIZE_E-2, 8, WIDTH, `CWIDTH*32, `AXI_ID_LEN) dcacheWriteIF
(
    .clk(clk),
    .rst(rst),

    .OUT_ready(DCW_ready),
    .IN_valid(DCW_valid),
    .IN_addr(DCW_addr),
    .IN_data(DCW_data),
    .IN_id(DCW_id),

    .OUT_ackValid(DCW_ackValid),
    .OUT_ackId(DCW_ackId),

    .IN_CACHE_ready(1'b1),
    .OUT_CACHE_ce(OUT_dcacheW.ce),
    .OUT_CACHE_we(OUT_dcacheW.we),
    .OUT_CACHE_wm(),
    .OUT_CACHE_addr(OUT_dcacheW.addr),
    .OUT_CACHE_data(OUT_dcacheW.data)
);
assign OUT_dcacheW.wm = '1;
assign OUT_dcacheR.wm = '0;
assign OUT_dcacheR.data = 'x;

function logic[`CACHE_SIZE_E-3:0] GetCacheRdAddr(Transfer t);
    case (t.cmd)
    MEMC_REPLACE, MEMC_CP_EXT_TO_CACHE:
        return {t.cacheAddr[`CACHE_SIZE_E-3:`CLSIZE_E-2], (t.cacheAddr[`CLSIZE_E-3:0] + t.addrCounter[`CLSIZE_E-3:0])};
    default:
        return t.cacheAddr;
    endcase
endfunction

// Read Data FIFO
localparam R_LEN = $bits(s_axi_rid) + $bits(s_axi_rdata) + $bits(s_axi_rlast);
logic[`AXI_ID_LEN-1:0] buf_rid;
logic[WIDTH-1:0] buf_rdata;
logic buf_rlast;
logic buf_rvalid;
logic buf_rready;
FIFO#(R_LEN, 32, 1, 1) rFIFO
(
    .clk(clk),
    .rst(rst),
    .free(),

    .IN_valid(s_axi_rvalid),
    .IN_data({s_axi_rid, s_axi_rdata, s_axi_rlast}),
    .OUT_ready(s_axi_rready),

    .OUT_valid(buf_rvalid),
    .IN_ready(buf_rready),
    .OUT_data({buf_rid, buf_rdata, buf_rlast})
);
// Forward AXI read data to cache
always_comb begin
    // Defaults
    buf_rready = 0;

    ICW_valid = 0;
    ICW_addr = 'x;
    ICW_data = 'x;
    ICW_id = 'x;

    DCW_valid = 0;
    DCW_addr = 'x;
    DCW_data = 'x;
    DCW_id = 'x;

    if (buf_rvalid) begin
        if (isMMIO[buf_rid]) begin
            buf_rready = 1;
        end
        else begin
            CacheID_t cID = transfers[buf_rid].cacheID;
            case (cID)
            0: if (DCW_ready && transfers[buf_rid].evictProgress > transfers[buf_rid].addrCounter) begin // dcache
                buf_rready = 1;
                DCW_valid = 1;
                DCW_addr = GetCacheRdAddr(transfers[buf_rid]);
                DCW_data = buf_rdata;
                DCW_id = buf_rid;

                if (transfers[buf_rid].addrCounter == 0) begin
                    for (integer i = 0; i < (`AXI_WIDTH/8); i=i+1)
                        if (transfers[buf_rid].storeMask[i]) begin
                            DCW_data[i*8+:8] = transfers[buf_rid].storeData[i*8+:8];
                        end
                end
            end

            1: if (ICW_ready) begin // icache
                buf_rready = 1;
                ICW_valid = 1;
                ICW_addr = GetCacheRdAddr(transfers[buf_rid]);
                ICW_data = buf_rdata;
                ICW_id = buf_rid;
            end
            endcase
        end
    end
end


logic DCR_reqReady;
logic DCR_reqValid;
logic[`AXI_ID_LEN-1:0] DCR_reqTId;
logic[7:0] DCR_reqLen;
logic[`CACHE_SIZE_E-3:0] DCR_reqAddr;
logic DCR_reqMMIO;
logic[31:0] DCR_reqMMIOData;

logic DCR_dataReady;
logic DCR_dataValid;
logic[WIDTH-1:0] DCR_data;
logic DCR_dataLast;
logic[`AXI_ID_LEN-1:0] DCR_dataTId;

logic DCR_CACHE_ready;
logic DCR_CACHE_ce;
logic DCR_CACHE_we;
logic[`CACHE_SIZE_E-3:0] DCR_CACHE_addr;

logic DCR_cacheReadValid;
logic[`AXI_ID_LEN-1:0] DCR_cacheReadId;
CacheReadInterface#(`CACHE_SIZE_E-2, 8, WIDTH, `CWIDTH*32, 32, `AXI_ID_LEN) dcacheReadIF
(
    .clk(clk),
    .rst(rst),

    .OUT_ready(DCR_reqReady),
    .IN_valid(DCR_reqValid),
    .IN_id(DCR_reqTId),
    .IN_len(DCR_reqLen),
    .IN_addr(DCR_reqAddr),
    .IN_mmio(DCR_reqMMIO),
    .IN_mmioData(DCR_reqMMIOData),

    .IN_ready(DCR_dataReady),
    .OUT_valid(DCR_dataValid),
    .OUT_id(DCR_dataTId),
    .OUT_data(DCR_data),
    .OUT_last(DCR_dataLast),

    .IN_CACHE_ready(IN_dcacheRReady),
    .OUT_CACHE_ce(OUT_dcacheR.ce),
    .OUT_CACHE_we(OUT_dcacheR.we),
    .OUT_CACHE_addr(OUT_dcacheR.addr),
    .IN_CACHE_data(IN_dcacheR),

    .OUT_cacheReadValid(DCR_cacheReadValid),
    .OUT_cacheReadId(DCR_cacheReadId)
);

// Begin Write Transactions
typedef struct packed
{
    logic[`AXI_ID_LEN-1:0]  awid;
    logic[ADDR_LEN-1:0] awaddr;
    logic[7:0] awlen;
    logic[2:0] awsize;
    logic[1:0] awburst;
    logic[0:0] awlock;
    logic[3:0] awcache;
    logic awvalid;
} AXI_AW;
AXI_AW axiAW;
logic awFIFO_outValid;
logic awFIFO_ready;
assign s_axi_awvalid = awFIFO_outValid;
FIFO#($bits(AXI_AW)-1, 4, 1, 1) awFIFO
(
    .clk(clk),
    .rst(rst),
    .free(),

    .IN_valid(axiAW.awvalid),
    .IN_data(axiAW[1+:$bits(AXI_AW)-1]),
    .OUT_ready(awFIFO_ready),

    .OUT_valid(awFIFO_outValid),
    .IN_ready(s_axi_awready),
    .OUT_data({s_axi_awid, s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst, s_axi_awlock, s_axi_awcache})
);
logic[`AXI_ID_LEN-1:0] awIdx;
logic awIdxValid;
always_comb begin
    reg isExclusive = 0;

    axiAW = 'x;
    axiAW.awvalid = 0;

    DCR_reqAddr = 'x;
    DCR_reqLen = 'x;
    DCR_reqTId = 'x;
    DCR_reqMMIOData = 'x;
    DCR_reqMMIO = 0;
    DCR_reqValid = 0;

    // Find Op that requires write request
    awIdx = 'x;
    awIdxValid = 0;
    for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
        if (transfers[i].valid && transfers[i].needWriteRq != 0) begin
            if (!isExclusive) begin
                // requests to cache and AXI must be made in the same order,
                // so a request made to only one of the two so far has priority
                isExclusive = transfers[i].needWriteRq != 2'b11;
                awIdx = i[$clog2(`AXI_NUM_TRANS)-1:0];
                awIdxValid = 1;
            end
            //else assert(transfers[i].needWriteRq != 2'b01 && transfers[i].needWriteRq != 2'b10);
        end
    end

    // Request to AXI
    if (awIdxValid && transfers[awIdx].needWriteRq[1]) begin
        axiAW.awvalid = 1;
        axiAW.awburst = isMMIO[awIdx] ? FIXED : WRAP;
        axiAW.awlen = isMMIO[awIdx] ? 0 : ((1 << (`CLSIZE_E - $clog2(WIDTH / 8))) - 1);
        axiAW.awaddr = transfers[awIdx].writeAddr;
        axiAW.awid = awIdx;

        case (transfers[awIdx].cmd)
            MEMC_WRITE_BYTE: axiAW.awsize = 0;
            MEMC_WRITE_HALF: axiAW.awsize = 1;
            MEMC_WRITE_WORD: axiAW.awsize = 2;
            default: axiAW.awsize = 3'($clog2(WIDTH/8));
        endcase
    end

    // Request to dcache read interface
    if (awIdxValid && transfers[awIdx].needWriteRq[0]) begin
        DCR_reqValid = 1;
        DCR_reqTId = awIdx;
        DCR_reqLen = isMMIO[awIdx] ? 0 : ((1 << (`CLSIZE_E - 2)) - 1);
        DCR_reqAddr = isMMIO[awIdx] ? 'x : transfers[awIdx].cacheAddr;
        DCR_reqMMIO = isMMIO[awIdx];
        DCR_reqMMIOData = isMMIO[awIdx] ? transfers[awIdx].storeData[31:0] : 'x;
    end
end

// Write Data
always_comb begin
    // Write requests are made in the same order on cache and AXI,
    // and write data has to be sent in-order on AXI4. As such,
    // we simply forward any data that the cache interface outputs.

    s_axi_wdata = 'x;
    s_axi_wstrb = 'x;
    s_axi_wlast = 'x;
    s_axi_wvalid = 0;

    if (DCR_dataValid) begin
        s_axi_wvalid = 1;
        s_axi_wlast = DCR_dataLast;
        s_axi_wstrb = '1;
        s_axi_wdata = DCR_data;
    end
end
assign DCR_dataReady = s_axi_wready;

assign s_axi_bready = 1;

// Input Transfers
always_ff@(posedge clk /*or posedge rst*/) begin

    sglStRes <= MemController_SglStRes'{default: 'x, valid: 0};
    sglLdRes <= MemController_SglLdRes'{default: 'x, valid: 0};
    ldDataFwd <= MemController_LdDataFwd'{default: 'x, valid: 0};

    if (rst) begin
        for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
            transfers[i] <= Transfer'{valid: 0, default: 'x};
        end
    end
    else begin

        // GC
        for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
            if (transfers[i].valid && transfers[i].readDone && transfers[i].writeDone) begin
                transfers[i] <= Transfer'{valid: 0, default: 'x};
            end
        end

        // Enqueue
        if (selReq.cmd != MEMC_NONE) begin
            assert(enqIdxValid);
            transfers[enqIdx].valid <= 1;
            transfers[enqIdx].cmd <= selReq.cmd;
            transfers[enqIdx].needReadRq <= '0;
            transfers[enqIdx].needWriteRq <= '0;
            transfers[enqIdx].progress <= 0;
            transfers[enqIdx].addrCounter <= 0;
            transfers[enqIdx].fwdAddrCounter <= 0;
            transfers[enqIdx].evictProgress <= (1 << (`CLSIZE_E - 2));
            transfers[enqIdx].cacheID <= selReq.cacheID;

            transfers[enqIdx].readDone <= 1;
            transfers[enqIdx].writeDone <= 1;

            if (selReq.cmd == MEMC_REPLACE || selReq.cmd == MEMC_CP_CACHE_TO_EXT || selReq.cmd == MEMC_CP_EXT_TO_CACHE) begin
                // cache-line oriented ops use aligned addresses
                transfers[enqIdx].writeAddr <= selReq.writeAddr & ~(WIDTH/8 - 1);
                transfers[enqIdx].readAddr <= selReq.readAddr & ~(WIDTH/8 - 1);
                transfers[enqIdx].cacheAddr <= selReq.cacheAddr & ~((WIDTH/8 - 1) >> 2);

                transfers[enqIdx].storeData <= selReq.data;
                transfers[enqIdx].storeMask <= selReq.mask;
            end
            else begin
                transfers[enqIdx].writeAddr <= selReq.writeAddr;
                transfers[enqIdx].readAddr <= selReq.readAddr;
                transfers[enqIdx].cacheAddr <= selReq.cacheAddr;

                transfers[enqIdx].storeData <= `AXI_WIDTH'(selReq.data);
                transfers[enqIdx].storeMask <= '1; // unused
            end

            case (selReq.cmd)
                MEMC_REPLACE: begin
                    transfers[enqIdx].needReadRq <= '1;
                    transfers[enqIdx].needWriteRq <= 2'b11;
                    transfers[enqIdx].evictProgress <= 0;
                    transfers[enqIdx].readDone <= 0;
                    transfers[enqIdx].writeDone <= 0;
                end
                MEMC_CP_EXT_TO_CACHE: begin
                    transfers[enqIdx].needReadRq <= '1;
                    transfers[enqIdx].readDone <= 0;
                end
                MEMC_CP_CACHE_TO_EXT: begin
                    transfers[enqIdx].needWriteRq <= 2'b11;
                    transfers[enqIdx].writeDone <= 0;
                    transfers[enqIdx].evictProgress <= 0;
                end
                MEMC_READ_BYTE, MEMC_READ_HALF, MEMC_READ_WORD: begin
                    transfers[enqIdx].needReadRq <= '1;
                    transfers[enqIdx].readDone <= 0;
                end
                MEMC_WRITE_BYTE, MEMC_WRITE_HALF, MEMC_WRITE_WORD: begin
                    transfers[enqIdx].needWriteRq <= 2'b11;
                    transfers[enqIdx].writeDone <= 0;
                end
                default: assert(0);
            endcase
        end

        // Read Request
        if (readReqSuccess) begin
            transfers[arIdx].needReadRq <= 0;
        end

        // Read Data
        if (buf_rvalid && buf_rready) begin

            transfers[buf_rid].addrCounter <= transfers[buf_rid].addrCounter + WIDTH_W;

            if (isMMIO[buf_rid]) begin
                transfers[buf_rid] <= Transfer'{valid: 0, default: 'x};

                sglLdRes.valid <= 1;
                sglLdRes.id <= transfers[buf_rid].cacheAddr;
                sglLdRes.data <= buf_rdata[31:0];
            end
        end

        if (s_axi_rvalid && s_axi_rready) begin
            if (transfers[s_axi_rid].cacheID == 0) begin
                transfers[s_axi_rid].fwdAddrCounter <= transfers[s_axi_rid].fwdAddrCounter + WIDTH_W;

                ldDataFwd.data <= s_axi_rdata;
                if (transfers[s_axi_rid].fwdAddrCounter == 0) begin
                    for (integer i = 0; i < `AXI_WIDTH/8; i=i+1)
                        if (transfers[s_axi_rid].storeMask[i])
                            ldDataFwd.data[i*8+:8] <= transfers[s_axi_rid].storeData[8*i+:8];
                end

                ldDataFwd.addr <= {transfers[s_axi_rid].readAddr[31:`CLSIZE_E], (transfers[s_axi_rid].readAddr[`CLSIZE_E-1:2] + transfers[s_axi_rid].fwdAddrCounter[`CLSIZE_E-3:0]), 2'b0};
                ldDataFwd.valid <= 1;
            end
        end

        // Read ACK
        if (DCW_ackValid) begin
            transfers[DCW_ackId].progress <= transfers[DCW_ackId].progress + WIDTH_W;
            if ((transfers[DCW_ackId].progress >> $clog2(WIDTH_W)) == (1 << (`CLSIZE_E - 2 - $clog2(WIDTH_W))) - 1) begin
                transfers[DCW_ackId].readDone <= 1;
                if (transfers[DCW_ackId].writeDone) begin
                    transfers[DCW_ackId] <= Transfer'{valid: 0, default: 'x};
                end
            end
        end
        if (ICW_ackValid) begin
            transfers[ICW_ackId].progress <= transfers[ICW_ackId].progress + WIDTH_W;
            if ((transfers[ICW_ackId].progress >> $clog2(WIDTH_W)) == (1 << (`CLSIZE_E - 2 - $clog2(WIDTH_W))) - 1) begin
                transfers[ICW_ackId].readDone <= 1;
                if (transfers[ICW_ackId].writeDone) begin
                    transfers[ICW_ackId] <= Transfer'{valid: 0, default: 'x};
                end
            end
        end

        // Write Request
        if (awIdxValid) begin
            if (DCR_reqValid && DCR_reqReady) transfers[awIdx].needWriteRq[0] <= 0;
            if (axiAW.awvalid && awFIFO_ready) transfers[awIdx].needWriteRq[1] <= 0;
        end

        // Write Data
        if (DCR_cacheReadValid) begin
            transfers[DCR_cacheReadId].evictProgress <= transfers[DCR_cacheReadId].evictProgress + WIDTH_W;
        end

        // Write ACK
        if (s_axi_bvalid) begin
            if (isMMIO[s_axi_bid]) begin
                sglStRes.valid <= 1;
                sglStRes.id <= transfers[s_axi_bid].cacheAddr;
            end
            transfers[s_axi_bid].writeDone <= 1;
            if (transfers[s_axi_bid].readDone) begin
                transfers[s_axi_bid] <= Transfer'{valid: 0, default: 'x};
            end
        end
    end
end

endmodule
