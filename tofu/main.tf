terraform {
  required_providers {
    incus = {
      source = "registry.terraform.io/lxc/incus"
    }
  }
}

provider "incus" {
  # OpenTofu detecta tu conexión local automáticamente
}

# Container 1: API Gateway
resource "incus_instance" "app-api" {
  name   = "app-api"
  image  = "images:ubuntu/22.04"
  config = { "security.nesting" = "true" }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = "red-reservas"
      "ipv4.address" = "10.10.0.97"
    }
  }
}

# Container 2: Backend Core
resource "incus_instance" "app-core" {
  name   = "app-core"
  image  = "images:ubuntu/22.04"
  config = { "security.nesting" = "true" }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = "red-reservas"
      "ipv4.address" = "10.10.0.96"
    }
  }
}

# Container 3: Base de Datos PostgreSQL
resource "incus_instance" "db-postgres" {
  name   = "db-postgres"
  image  = "images:ubuntu/22.04"
  config = { "security.nesting" = "true" }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = "red-reservas"
      "ipv4.address" = "10.10.0.95"
    }
  }
}

# Container 4: Monitoreo
resource "incus_instance" "monitoring" {
  name   = "monitoring"
  image  = "images:ubuntu/22.04"
  config = { "security.nesting" = "true" }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = "red-reservas"
      "ipv4.address" = "10.10.0.98"
    }
  }
}
