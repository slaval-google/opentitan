// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Buffered partition for OTP controller.
//

`include "prim_assert.sv"

module otp_ctrl_part_buf
  import otp_ctrl_pkg::*;
  import otp_ctrl_reg_pkg::*;
#(
  // Partition information.
  parameter part_info_t Info
) (
  input                               clk_i,
  input                               rst_ni,
  // Pulse to start partition initialisation (required once per power cycle).
  input                               init_req_i,
  output logic                        init_done_o,
  // Integrity check requests
  input                               integ_chk_req_i,
  output logic                        integ_chk_ack_o,
  // Consistency check requests
  input                               cnsty_chk_req_i,
  output logic                        cnsty_chk_ack_o,
  // Escalation input. This moves the FSM into a terminal state and locks down
  // the partition.
  input  lc_tx_t                      escalate_en_i,
  // Output error state of partition, to be consumed by OTP error/alert logic.
  // Note that most errors are not recoverable and move the partition FSM into
  // a terminal error state.
  output otp_err_e                    error_o,
  // Access/lock status
  input  part_access_t                access_i, // runtime lock from CSRs
  output part_access_t                access_o,
  // Buffered 64bit digest output.
  output logic [ScrmblBlockWidth-1:0] digest_o,
  output logic [Info.size*8-1:0]      data_o,
  // OTP interface
  output logic                        otp_req_o,
  output prim_otp_cmd_e               otp_cmd_o,
  output logic [OtpSizeWidth-1:0]     otp_size_o,
  output logic [OtpIfWidth-1:0]       otp_wdata_o,
  output logic [OtpAddrWidth-1:0]     otp_addr_o,
  input                               otp_gnt_i,
  input                               otp_rvalid_i,
  input  [ScrmblBlockWidth-1:0]       otp_rdata_i,
  input  otp_err_e                    otp_err_i,
  // Scrambling mutex request
  output logic                        scrmbl_mtx_req_o,
  input                               scrmbl_mtx_gnt_i,
  // Scrambling datapath interface
  output otp_scrmbl_cmd_e             scrmbl_cmd_o,
  output logic [ConstSelWidth-1:0]    scrmbl_sel_o,
  output logic [ScrmblBlockWidth-1:0] scrmbl_data_o,
  output logic                        scrmbl_valid_o,
  input  logic                        scrmbl_ready_i,
  input  logic                        scrmbl_valid_i,
  input  logic [ScrmblBlockWidth-1:0] scrmbl_data_i
);

  ////////////////////////
  // Integration Checks //
  ////////////////////////

  import prim_util_pkg::vbits;

  localparam int DigestOffset = Info.offset + Info.size - ScrmblBlockWidth/8;
  localparam int NumScrmblBlocks = Info.size / (ScrmblBlockWidth/8);
  localparam int CntWidth = vbits(NumScrmblBlocks);

  // Integration checks for parameters.
  `ASSERT_INIT(OffsetMustBeBlockAligned_A, Info.offset % ScrmblBlockWidth/8 == 0)
  `ASSERT_INIT(SizeMustBeBlockAligned_A, Info.size % ScrmblBlockWidth/8 == 0)
  `ASSERT(ScrambledImpliesDigest_A, Info.scrambled |-> Info.hw_digest)
  `ASSERT(WriteLockImpliesDigest_A, Info.read_lock |-> Info.hw_digest)
  `ASSERT(ReadLockImpliesDigest_A, Info.write_lock |-> Info.hw_digest)

  ///////////////////////
  // OTP Partition FSM //
  ///////////////////////

  // Encoding generated with ./sparse-fsm-encode -d 5 -m 16 -n 12
  // Hamming distance histogram:
  //
  // 0:  --
  // 1:  --
  // 2:  --
  // 3:  --
  // 4:  --
  // 5:  |||||||||||||||| (29.17%)
  // 6:  |||||||||||||||||||| (35.83%)
  // 7:  ||||||||||| (20.83%)
  // 8:  |||| (7.50%)
  // 9:  | (2.50%)
  // 10: | (3.33%)
  // 11:  (0.83%)
  // 12: --
  //
  // Minimum Hamming distance: 5
  // Maximum Hamming distance: 11
  //
  typedef enum logic [11:0] {
    ResetSt         = 12'b110001101001,
    InitSt          = 12'b000100100000,
    InitWaitSt      = 12'b011101011010,
    InitDescrSt     = 12'b111010110000,
    InitDescrWaitSt = 12'b110111000011,
    IdleSt          = 12'b000000011100,
    IntegScrSt      = 12'b001111101011,
    IntegScrWaitSt  = 12'b000001000111,
    IntegDigClrSt   = 12'b100110001101,
    IntegDigSt      = 12'b101000110111,
    IntegDigPadSt   = 12'b110101010100,
    IntegDigFinSt   = 12'b101011001000,
    IntegDigWaitSt  = 12'b010010101111,
    CnstyReadSt     = 12'b001110000110,
    CnstyReadWaitSt = 12'b011011011101,
    ErrorSt         = 12'b000111110101
  } state_e;

  typedef enum logic {
    ScrmblData,
    OtpData
  } data_sel_e;

  typedef enum logic {
    PartOffset,
    DigOffset
  } base_sel_e;

  state_e state_d, state_q;
  otp_err_e error_d, error_q;
  data_sel_e data_sel;
  base_sel_e base_sel;
  access_e dout_gate_d, dout_gate_q;
  logic [CntWidth-1:0] cnt_d, cnt_q;
  logic cnt_en, cnt_clr;
  logic parity_err;
  logic buffer_reg_en;
  logic [ScrmblBlockWidth-1:0] data_mux;

  // Output partition error state.
  assign error_o = error_q;

  // This partition cannot do any write accesses, hence we tie this
  // constantly off.
  assign otp_wdata_o = '0;
  assign otp_cmd_o   = OtpRead;

  always_comb begin : p_fsm
    state_d = state_q;

    // Redundantly encoded lock signal for buffer regs.
    dout_gate_d = dout_gate_q;

    // OTP signals
    otp_req_o = 1'b0;

    // Scrambling mutex
    scrmbl_mtx_req_o = 1'b0;

    // Scrambling datapath
    scrmbl_cmd_o   = LoadShadow;
    scrmbl_sel_o   = '0;
    scrmbl_valid_o = 1'b0;

    // Counter
    cnt_en   = 1'b0;
    cnt_clr  = 1'b0;
    base_sel = PartOffset;

    // Buffer register
    buffer_reg_en = 1'b0;
    data_sel = OtpData;

    // Error Register
    error_d = error_q;

    // Integrity/Consistency check responses
    cnsty_chk_ack_o = 1'b0;
    integ_chk_ack_o = 1'b0;

    unique case (state_q)
      ///////////////////////////////////////////////////////////////////
      // State right after reset. Wait here until we get a an
      // initialization request.
      ResetSt: begin
        if (init_req_i) begin
          state_d = InitSt;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Initialization reads out the digest only in unbuffered
      // partitions. Wait here until the OTP request has been granted.
      // And then wait until the OTP word comes back.
      InitSt: begin
        otp_req_o = 1'b1;
        if (otp_gnt_i) begin
          state_d = InitWaitSt;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Wait for OTP response and write to buffer register, then go to
      // descrambling state. In case an OTP transaction fails, latch the
      // OTP error code and jump to a
      // terminal error state.
      InitWaitSt: begin
        if (otp_rvalid_i) begin
          buffer_reg_en = 1'b1;
          // The only error we tolerate is an ECC soft error. However,
          // we still signal that error via the error state output.
          if (!(otp_err_i inside {NoErr, OtpReadCorrErr})) begin
            state_d = ErrorSt;
            error_d = otp_err_i;
          end else begin
            // Once we've read and descrambled the whole partition, we can go to integrity
            // verification. Note that the last block is the digest value, which does not
            // have to be descrambled.
            if (cnt_q == NumScrmblBlocks-1) begin
              state_d = IntegDigClrSt;
            // Only need to descramble if this is a scrambled partition.
            // Otherwise, we can just go back to InitSt and read the next block.
            end else if (Info.scrambled) begin
              state_d = InitDescrSt;
            end else begin
              state_d = InitSt;
              cnt_en = 1'b1;
            end
            // Signal ECC soft errors, but do not go into terminal error state.
            if (otp_err_i == OtpReadCorrErr) begin
              error_d = otp_err_i;
            end
          end
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Descrambling state. This first acquires the scrambling
      // datapath mutex. Note that once the mutex is acquired, we have
      // exclusive access to the scrambling datapath until we release
      // the mutex by deasserting scrmbl_mtx_req_o.
      InitDescrSt: begin
        scrmbl_mtx_req_o = 1'b1;
        scrmbl_valid_o = 1'b1;
        scrmbl_cmd_o = Decrypt;
        scrmbl_sel_o = Info.key_idx;
        if (scrmbl_mtx_gnt_i && scrmbl_ready_i) begin
          state_d = InitDescrWaitSt;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Wait for the descrambled data to return. Note that we release
      // the mutex lock upon leaving this state.
      InitDescrWaitSt: begin
        scrmbl_mtx_req_o = 1'b1;
        scrmbl_sel_o = Info.key_idx;
        data_sel = ScrmblData;
        if (scrmbl_valid_i) begin
          state_d = InitSt;
          buffer_reg_en = 1'b1;
          cnt_en = 1'b1;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Idle state. We basically wait for integrity and consistency check
      // triggers in this state.
      IdleSt: begin
        if (integ_chk_req_i) begin
          state_d = IntegDigClrSt;
        end else if (cnsty_chk_req_i) begin
          state_d = CnstyReadSt;
          cnt_clr = 1'b1;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Read the digest. Wait here until the OTP request has been granted.
      // And then wait until the OTP word comes back.
      CnstyReadSt: begin
        otp_req_o = 1'b1;
        // In case this partition has a hardware digest, we only have to read
        // and compare the digest value. In that case we select the digest offset here.
        // Otherwise we have to read and compare the whole partition, in which case we
        // select the partition offset, which is the default assignment of base_sel.
        if (Info.hw_digest) begin
          base_sel = DigOffset;
        end
        if (otp_gnt_i) begin
          state_d = CnstyReadWaitSt;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Wait for OTP response and and compare the digest. In case there is
      // a mismatch, lock down the partition and go into the terminal error
      // state. In case an OTP transaction fails, latch the OTP error code
      // and jump to a terminal error state.
      CnstyReadWaitSt: begin
        if (otp_rvalid_i) begin
          // The only error we tolerate is an ECC soft error. However,
          // we still signal that error via the error state output.
          if (!(otp_err_i inside {NoErr, OtpReadCorrErr})) begin
            state_d = ErrorSt;
            error_d = otp_err_i;
          end else begin
            // Check whether we need to compare the digest or the full partition
            // contents here.
            if (Info.hw_digest) begin
              // Note that we ignore this check if the digest is still blank.
              if (digest_o == data_mux || data_mux == '0 && digest_o == '0) begin
                state_d = IdleSt;
                cnsty_chk_ack_o = 1'b1;
              // Error out and lock the partition if this check fails.
              end else begin
                state_d = ErrorSt;
                error_d = CnstyErr;
              end
            end else begin
              // Check whether the read data corresponds with the data buffered in regs.
              if (scrmbl_data_o == data_mux) begin
                // Can go back to idle and acknowledge the
                // request if this is the last block.
                if (cnt_q == NumScrmblBlocks-1) begin
                  state_d = IdleSt;
                  cnsty_chk_ack_o = 1'b1;
                // Need to go back and read out more blocks.
                end else begin
                  state_d = CnstyReadSt;
                  cnt_en = 1'b1;
                end
              end else begin
                state_d = ErrorSt;
                error_d = CnstyErr;
              end
            end
          end
        end
      end
      ///////////////////////////////////////////////////////////////////
      // First, acquire the mutex for the digest and clear the digest state.
      IntegDigClrSt: begin
        // Check whether this partition requires checking at all.
        if (Info.hw_digest) begin
          scrmbl_mtx_req_o = 1'b1;
          scrmbl_valid_o = 1'b1;
          cnt_clr = 1'b1;
          // Need to reset the digest state and set it to chained
          // mode if this partition is scrambled.
          scrmbl_cmd_o = DigestInit;
          if (Info.scrambled) begin
            scrmbl_sel_o = ChainedMode;
            if (scrmbl_mtx_gnt_i && scrmbl_ready_i) begin
              state_d = IntegScrSt;
            end
          // If this partition is not scrambled, we can just directly
          // jump to the digest state.
          end else begin
            scrmbl_sel_o = StandardMode;
            if (scrmbl_mtx_gnt_i && scrmbl_ready_i) begin
              state_d = IntegDigSt;
            end
          end
        // Otherwise, if this partition is not digest protected,
        // we can just acknowledge the request and return to idle,
        // since there is nothing to check.
        end else begin
          state_d = IdleSt;
          integ_chk_ack_o = 1'b1;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Scramble buffered data (which is held in plaintext form).
      // This moves the previous scrambling result into the shadow reg
      // for later use.
      IntegScrSt: begin
          scrmbl_mtx_req_o = 1'b1;
          scrmbl_valid_o = 1'b1;
          scrmbl_cmd_o = Encrypt;
          scrmbl_sel_o = Info.key_idx;
          if (scrmbl_ready_i) begin
            state_d = IntegScrWaitSt;
          end
      end
      ///////////////////////////////////////////////////////////////////
      // Wait for the scrambled data to return.
      IntegScrWaitSt: begin
        scrmbl_mtx_req_o = 1'b1;
        scrmbl_sel_o = Info.key_idx;
        if (scrmbl_valid_i) begin
          state_d = IntegDigSt;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Push the word read into the scrambling datapath. The last
      // block is repeated in case the number blocks in this partition
      // is odd.
      IntegDigSt: begin
        scrmbl_mtx_req_o = 1'b1;
        scrmbl_valid_o = 1'b1;
        if (scrmbl_ready_i) begin
          cnt_en = 1'b1;
          // No need to digest the digest value itself
          if (cnt_q == NumScrmblBlocks-2) begin
            // Note that the digest operates on 128bit blocks since the data is fed in via the
            // PRESENT key input. Therefore, we only trigger a digest update on every second
            // 64bit block that is pushed into the scrambling datapath.
            if (cnt_q[0]) begin
              scrmbl_cmd_o = Digest;
              state_d = IntegDigFinSt;
            end else begin
              state_d = IntegDigPadSt;
            end
          end else begin
            // Trigger digest round in case this is the second block in a row.
            if (cnt_q[0]) begin
              scrmbl_cmd_o = Digest;
            end
            // Go back and scramble the next data block if this is
            // a scrambled partition. Otherwise just stay here.
            if (Info.scrambled) begin
              state_d = IntegScrSt;
            end
          end
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Padding state. When we get here, we've copied the last encryption
      // result into the shadow register such that we've effectively
      // repeated the last block twice in order to pad the data to 128bit.
      IntegDigPadSt: begin
        scrmbl_mtx_req_o = 1'b1;
        scrmbl_valid_o = 1'b1;
        scrmbl_cmd_o = Digest;
        if (scrmbl_ready_i) begin
          state_d = IntegDigFinSt;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Trigger digest finalization and go wait for the result.
      IntegDigFinSt: begin
        scrmbl_mtx_req_o = 1'b1;
        scrmbl_valid_o = 1'b1;
        scrmbl_cmd_o = DigestFinalize;
        if (scrmbl_ready_i) begin
          state_d = IntegDigWaitSt;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Wait for the digest to return, and double check whether the digest
      // matches. If yes, unlock the partition. Otherwise, go into the terminal
      // error state, where the partition will be locked down.
      IntegDigWaitSt: begin
        scrmbl_mtx_req_o = 1'b1;
        data_sel = ScrmblData;
        if (scrmbl_valid_i) begin
          // This is the only way the buffer regs can get unlocked.
          // Note that we ignore this check if the digest is still blank.
          if (digest_o == data_mux || digest_o == '0) begin
            state_d = IdleSt;
            // If the partition is still locked, this is the first integrity check after
            // initialization. This is the only way the buffer regs can get unlocked.
            if (dout_gate_q != Unlocked) begin
              dout_gate_d = Unlocked;
            // Otherwise, this integrity check has requested by the LFSR timer, and we have
            // to acknowledge its completion.
            end else begin
              integ_chk_ack_o = 1'b1;
            end
          // Error out and lock the partition if this check fails.
          end else begin
            state_d = ErrorSt;
            error_d = IntegErr;
          end
        end
      end
      ///////////////////////////////////////////////////////////////////
      // Terminal Error State. This locks access to the partition.
      // Make sure the partition signals an error state if no error
      // code has been latched so far, and lock the buffer regs down.
      ErrorSt: begin
        dout_gate_d = Locked;
        if (!error_q) begin
          error_d = FsmErr;
        end
      end
      ///////////////////////////////////////////////////////////////////
      // We should never get here. If we do (e.g. via a malicious
      // glitch), error out immediately.
      default: begin
        state_d = ErrorSt;
      end
      ///////////////////////////////////////////////////////////////////
    endcase // state_q

    if (state_q != ErrorSt) begin
      // Unconditionally jump into the terminal error state in case of
      // a parity error or escalation, and lock access to the partition down.
      if (parity_err) begin
        state_d = ErrorSt;
        error_d = ParityErr;
      end
      if (escalate_en_i != Off) begin
        state_d = ErrorSt;
        error_d = EscErr;
      end
    end
  end

  ////////////////////////////
  // Address Calc and Muxes //
  ////////////////////////////

  // Address counter - this is only used for computing a digest, hence the increment is
  // fixed to 8 byte.
  assign cnt_d = (cnt_clr) ? '0           :
                 (cnt_en)  ? cnt_q + 1'b1 : cnt_q;

  logic [OtpByteAddrWidth-1:0] addr_base;
  assign addr_base = (base_sel == DigOffset) ? DigestOffset : Info.offset;

  // Note that OTP works on halfword (16bit) addresses, hence need to
  // shift the addresses appropriately.
  logic [OtpByteAddrWidth-1:0] addr_calc;
  assign addr_calc = OtpByteAddrWidth'({cnt_q, {$clog2(ScrmblBlockWidth/8){1'b0}}}) + addr_base;
  assign otp_addr_o = addr_calc >> OtpAddrShift;

  // Always transfer 64bit blocks.
  assign otp_size_o = OtpSizeWidth'(unsigned'(ScrmblBlockWidth / OtpWidth) - 1);

  assign scrmbl_data_o = data_o[cnt_q << $clog2(ScrmblBlockWidth) +: ScrmblBlockWidth];

  assign data_mux = (data_sel == ScrmblData) ? scrmbl_data_i : otp_rdata_i;

  /////////////////
  // Buffer Regs //
  /////////////////

  // TODO: need to add secure erase feature here.
  logic [Info.size*8-1:0] data;
  otp_ctrl_parity_reg #(
    .Width ( ScrmblBlockWidth ),
    .Depth ( NumScrmblBlocks  )
  ) u_otp_ctrl_parity_reg (
    .clk_i,
    .rst_ni,
    .wren_i       ( buffer_reg_en ),
    .addr_i       ( cnt_q         ),
    .wdata_i      ( data_mux      ),
    .data_o       ( data          ),
    .parity_err_o ( parity_err    )
  );

  // Hardware output gating.
  // Note that this is decoupled from the DAI access rules further below.
  // TODO: This may need a data-specific default.
  assign data_o = (dout_gate_q == Unlocked) ? data : '0;
  // The digest does not have to be gated.
  assign digest_o = data[$high(data_o) -: ScrmblBlockWidth];
  // We have successfully initialized the partition once it has been unlocked.
  assign init_done_o = (dout_gate_q == Unlocked);


  ////////////////////////
  // DAI Access Control //
  ////////////////////////

  // Aggregate all possible DAI write locks. The partition is also locked when uninitialized.
  // Note that the locks are redundantly encoded values.
  if (Info.write_lock) begin : gen_digest_write_lock
    assign access_o.write_lock = ((dout_gate_q != Unlocked) ||
                                  (access_i.write_lock != Unlocked) ||
                                  (digest_o != '0))  ? Locked : Unlocked;
    `ASSERT(DigestWriteLocksPartition_A, digest_o |-> access_o.write_lock == Locked)
  end else begin : gen_no_digest_write_lock
    assign access_o.write_lock = ((dout_gate_q != Unlocked) ||
                                  (access_i.write_lock != Unlocked)) ? Locked : Unlocked;
  end

  // Aggregate all possible DAI read locks. The partition is also locked when uninitialized.
  // Note that the locks are redundantly encoded 16bit values.
  if (Info.read_lock) begin : gen_digest_read_lock
    assign access_o.read_lock = ((dout_gate_q != Unlocked) ||
                                 (access_i.read_lock != Unlocked) ||
                                 (digest_o != '0)) ? Locked : Unlocked;
    `ASSERT(DigestReadLocksPartition_A, digest_o |-> access_o.read_lock == Locked)
  end else begin : gen_no_digest_read_lock
    assign access_o.read_lock = ((dout_gate_q != Unlocked) ||
                                 (access_i.read_lock != Unlocked)) ? Locked : Unlocked;
  end

  ///////////////
  // Registers //
  ///////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      state_q     <= ResetSt;
      error_q     <= NoErr;
      cnt_q       <= '0;
      dout_gate_q <= Locked;
    end else begin
      state_q     <= state_d;
      error_q     <= error_d;
      cnt_q       <= cnt_d;
      dout_gate_q <= dout_gate_d;
    end
  end

  ////////////////
  // Assertions //
  ////////////////

  // Known assertions
  `ASSERT_KNOWN(InitDoneKnown_A,  init_done_o)
  `ASSERT_KNOWN(ErrorKnown_A,     error_o)
  `ASSERT_KNOWN(AccessKnown_A,    access_o)
  `ASSERT_KNOWN(DataKnown_A,      data_o)
  `ASSERT_KNOWN(DigestKnown_A,    digest_o)

  `ASSERT_KNOWN(OtpReqKnown_A,    otp_req_o)
  `ASSERT_KNOWN(OtpCmdKnown_A,    otp_cmd_o)
  `ASSERT_KNOWN(OtpSizeKnown_A,   otp_size_o)
  `ASSERT_KNOWN(OtpWdataKnown_A,  otp_wdata_o)
  `ASSERT_KNOWN(OtpAddrKnown_A,   otp_addr_o)

  // Uninitialized partitions should always be locked, no matter what.
  `ASSERT(InitWriteLocksPartition_A,
      dout_gate_q != Unlocked
      |->
      access_o.write_lock == Locked)
  `ASSERT(InitReadLocksPartition_A,
      dout_gate_q != Unlocked
      |->
      access_o.read_lock == Locked)
  // Incoming Lock propagation
  `ASSERT(WriteLockPropagation_A,
      access_i.write_lock != Unlocked
      |->
      access_o.write_lock == Locked)
  `ASSERT(ReadLockPropagation_A,
      access_i.read_lock != Unlocked
      |->
      access_o.read_lock == Locked)
  // Parity error
  `ASSERT(ParityErrorState_A,
      parity_err
      |=>
      state_q == ErrorSt)
  // OTP error response
  `ASSERT(OtpErrorState_A,
      state_q inside {InitWaitSt, CnstyReadWaitSt} && otp_rvalid_i &&
      !(otp_err_i inside {NoErr, OtpReadCorrErr}) && !parity_err
      |=>
      state_q == ErrorSt && error_o == $past(otp_err_i))

endmodule : otp_ctrl_part_buf