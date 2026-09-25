# SPDX-License-Identifier: BSD-2-Clause-Views
#
# ssr_core timing constraints
#
# Scoped the same way Corundum scopes its own module constraints: find every
# instance of the module by reference name, then constrain relative to it, so
# the file survives hierarchy changes and multiple instantiations.

foreach inst [get_cells -hier -filter {(ORIG_REF_NAME == ssr_core || REF_NAME == ssr_core)}] {
    puts "Inserting timing constraints for ssr_core instance $inst"

    # ---------------------------------------------------------------------
    # Round arithmetic: nothing to constrain
    # ---------------------------------------------------------------------
    #
    # round_id = sec * ROUNDS_PER_SECOND + ns / ROUND_LENGTH_NS. An earlier
    # version computed both terms combinationally - a 48 x 18-bit constant
    # product and a 32-bit division by 4000 - on the arming path, and this
    # file carried a (disabled) multicycle constraint for the product with a
    # long warning about the RTL guard it would need. Both terms are now
    # computed bit-serially in ssr_core.v (one adder each, 34 cycles per
    # result, tagged with the seconds value they were computed from, checked
    # by the consumer). Every path is a single 64-bit add or compare, so the
    # module needs no exception; if it fails timing, something else is wrong.

    # ---------------------------------------------------------------------
    # Clock domain
    # ---------------------------------------------------------------------
    # No CDC constraints here, deliberately. ssr_core takes PTP time via
    # ptp_sync_ts_tod, which mqnic_ptp_clock's ptp_td_leaf instance generates in
    # the core clk domain - the wide timestamp never crosses a domain, only the
    # single-bit ptp_td_sd stream does, and ptp_td_leaf.tcl already constrains
    # that. ssr_core must therefore always be clocked by the same clk that
    # is passed to mqnic_ptp. If that ever changes, a 96-bit value starts
    # crossing domains unsynchronised and this file needs a real CDC section.
}
