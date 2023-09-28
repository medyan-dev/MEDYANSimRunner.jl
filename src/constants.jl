const THIS_PACKAGE_VERSION::String = string(pkgversion(@__MODULE__))

const DATE_FORMAT = Dates.dateformat"yyyy-mm-ddTHH:MM:SS"

# amount to pad step count.
# This cannot be changed.
const STEP_PAD = 10