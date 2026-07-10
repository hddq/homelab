output "instance_public_ip" {
  value       = oci_core_instance.free_instance.public_ip
  description = "The public IP address of the Always Free instance"
}

output "instance_state" {
  value       = oci_core_instance.free_instance.state
  description = "The current state of the instance"
}
