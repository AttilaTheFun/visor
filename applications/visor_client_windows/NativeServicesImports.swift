// What the portable services (//libraries/visor_services:native_srcs) see
// in the module they make here, imported for all of it so they compile as
// they are: the protocols they implement (inside VisorServices on Apple's
// systems), and URLSession, which this system's Foundation keeps in
// FoundationNetworking.

@_exported import FoundationNetworking
@_exported import VisorServices
