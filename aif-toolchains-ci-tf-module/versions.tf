terraform {
  required_version = "= 1.15.8"

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "= 2.5.0"
    }
  }
}