# Ryloth direct-HBM probe floorplan: the outer PR pblock of the proven 0518 design (SLR1+SLR2), nothing else.
create_pblock pblock_inst_user_wrapper_0
add_cells_to_pblock [get_pblocks pblock_inst_user_wrapper_0] [get_cells -quiet [list inst_shell/inst_dynamic/inst_user_wrapper_0]]
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {CLOCKREGION_X0Y5:CLOCKREGION_X3Y10}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {URAM288_X0Y64:URAM288_X1Y79}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {RAMB18_X0Y96:RAMB18_X3Y119}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {RAMB36_X0Y48:RAMB36_X3Y59}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {DSP48E2_X0Y90:DSP48E2_X7Y113}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {CLOCKREGION_X4Y7:CLOCKREGION_X7Y10}
set_property SNAPPING_MODE ON [get_pblocks pblock_inst_user_wrapper_0]
set_property IS_SOFT FALSE [get_pblocks pblock_inst_user_wrapper_0]
set_property CONTAIN_ROUTING TRUE [get_pblocks pblock_inst_user_wrapper_0]
