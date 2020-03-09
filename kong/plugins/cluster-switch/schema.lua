local typedefs = require "kong.db.schema.typedefs"


return {
  name = "cluster-switch",
  fields = {
    { consumer = typedefs.no_consumer },
    { run_on = typedefs.run_on_first },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { apollo_address = { type = "string", default = "apollo-configservice.apollo.svc.cluster.local:8080" }, },
          { apollo_app_id = { type = "string", default = "cluster-switch" }, },
          { apollo_namespace = { type = "string", default = "cluster-switch" }, },
          { apollo_cluster = { type = "string", default = "default" }, },
        },
      }
    }
  },
}
