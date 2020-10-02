// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// basic sanity test vseq
class otp_ctrl_wake_up_vseq extends otp_ctrl_base_vseq;
  `uvm_object_utils(otp_ctrl_wake_up_vseq)

  `uvm_object_new

  virtual task otp_ctrl_init();
    super.otp_ctrl_init();
    // drive pwr_otp_req pin
    cfg.pwr_otp_vif.drive_pin(0, 1);
    // reset memory to avoid readout X
    cfg.mem_bkdr_vif.clear_mem();
  endtask

  virtual task pre_start();
    super.pre_start();
  endtask

  task body();
    bit [TL_DW-1:0] rand_addr = $urandom_range(0, 768);
    dut_init();

    // wait until otp-init done, check status
    wait(cfg.pwr_otp_vif.pins[2] == 1);
    cfg.pwr_otp_vif.drive_pin(0, 0);
    cfg.clk_rst_vif.wait_clks(1);
    csr_wr(ral.intr_enable, 2'b11);
    csr_rd_check(.ptr(ral.status), .compare_value(2));

    // write seq
    csr_wr(ral.direct_access_address, rand_addr);
    csr_wr(ral.direct_access_wdata_0, '1);
    csr_wr(ral.direct_access_cmd, 2);
    wait(cfg.intr_vif.pins[OtpOperationDone] == 1);
    csr_wr(ral.intr_state, 2'b11);

    // read seq
    csr_wr(ral.direct_access_address, rand_addr);
    csr_wr(ral.direct_access_cmd, 1);
    wait(cfg.intr_vif.pins[OtpOperationDone] == 1);
    csr_rd_check(.ptr(ral.direct_access_rdata_0), .compare_value('1));
    csr_wr(ral.intr_state, 2'b11);

    // digest sw error seq
    csr_wr(ral.direct_access_address, 2);
    csr_wr(ral.direct_access_cmd, 4);
    wait(cfg.intr_vif.pins[OtpOperationDone] == 1);
    wait(cfg.intr_vif.pins[OtpErr] == 1);
    csr_wr(ral.intr_state, 2'b11);

    // digest hw seq
    csr_wr(ral.direct_access_address, 11'h600);
    csr_wr(ral.direct_access_cmd, 4);
    wait(cfg.intr_vif.pins[OtpOperationDone] == 1);
    csr_wr(ral.intr_state, OtpOperationDone);

  endtask : body

endclass : otp_ctrl_wake_up_vseq