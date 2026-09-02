# The composed application floorplan starts with the exact parent QShell V80
# floorplan, which already reserves BUFGCE_DIV_X6Y0:X6Y3 and VNOC high IDs
# 6 through 63 before the parent link. No late application-side pblock mutation
# is legal or required here. Keep this extension as XDC-only documentation;
# source/package checks validate the parent reservation before implementation.
