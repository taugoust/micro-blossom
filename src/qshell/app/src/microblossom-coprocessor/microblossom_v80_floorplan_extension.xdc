# The QShell V80 application pblock spans clock-region columns X5 through X7.
# Include the corresponding divider buffers required by MicroBlossom's local clock.
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add \
    {BUFGCE_DIV_X5Y0:BUFGCE_DIV_X7Y3}
