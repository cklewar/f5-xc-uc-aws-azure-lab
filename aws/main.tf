module "vpc" {
  source             = "../modules/aws/vpc"
  aws_region         = var.aws_region
  aws_az_name        = var.aws_az_name
  aws_vpc_name       = format("%s-vpc", var.site_name)
  aws_vpc_cidr_block = var.vpc_cidr_block
  custom_tags        = var.custom_tags
}

module "subnet" {
  source          = "../modules/aws/subnet"
  aws_vpc_id      = module.vpc.aws_vpc["id"]
  aws_vpc_subnets = [
    {
      cidr_block              = var.outside_subnet_cidr_block, availability_zone = var.aws_az_name,
      map_public_ip_on_launch = "true", custom_tags = { "Name" = format("%s-sn-outside", var.site_name) }
    },
    {
      cidr_block              = var.inside_subnet_cidr_block, availability_zone = var.aws_az_name,
      map_public_ip_on_launch = "false", custom_tags = { "Name" = format("%s-sn-inside", var.site_name) }
    },
    {
      cidr_block              = var.workload_subnet_cidr_block, availability_zone = var.aws_az_name,
      map_public_ip_on_launch = "true", custom_tags = { "Name" = format("%s-sn-workload", var.site_name) }
    }
  ]
  custom_tags = var.custom_tags
}

module "site" {
  source                   = "../modules/f5xc/site/aws/vpc"
  f5xc_api_token           = var.f5xc_api_token
  f5xc_api_url             = var.f5xc_api_url
  f5xc_tenant              = var.f5xc_tenant
  f5xc_aws_cred            = var.f5xc_aws_cred
  f5xc_namespace           = "system"
  f5xc_aws_region          = var.aws_region
  f5xc_aws_ce_gw_type      = "multi_nic"
  f5xc_aws_vpc_name_tag    = var.site_name
  f5xc_aws_vpc_site_name   = var.site_name
  f5xc_aws_vpc_existing_id = module.vpc.aws_vpc["id"]
  f5xc_aws_vpc_az_nodes    = {
    node0 : {
      f5xc_aws_vpc_outside_existing_subnet_id  = module.subnet.aws_subnets[format("%s-sn-outside", var.site_name)]["id"],
      f5xc_aws_vpc_inside_existing_subnet_id   = module.subnet.aws_subnets[format("%s-sn-inside", var.site_name)]["id"],
      f5xc_aws_vpc_workload_existing_subnet_id = module.subnet.aws_subnets[format("%s-sn-workload", var.site_name)]["id"],
      f5xc_aws_vpc_az_name                     = var.aws_az_name
    }
  }
  f5xc_aws_vpc_no_worker_nodes         = true
  f5xc_aws_default_ce_os_version       = true
  f5xc_aws_default_ce_sw_version       = true
  f5xc_aws_vpc_use_http_https_port     = true
  f5xc_aws_vpc_inside_static_routes    = [var.workload_subnet_cidr_block]
  f5xc_aws_vpc_use_http_https_port_sli = true
  public_ssh_key                       = var.ssh_public_key_file
  custom_tags                          = var.custom_tags
}

resource "aws_internet_gateway" "igw" {
  vpc_id = module.vpc.aws_vpc["id"]
  tags   = var.custom_tags
}

resource "aws_route_table" "rt" {
  vpc_id = module.vpc.aws_vpc["id"]
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = var.custom_tags
}

#resource "aws_route_table_association" "subnet" {
#  for_each       = module.subnet.aws_subnets
#  subnet_id      = each.value.id
#  route_table_id = aws_route_table.rt.id
#}

module "aws_security_group_public" {
  source                     = "../modules/aws/security_group"
  aws_security_group_name    = format("%s-public-sg", var.site_name)
  aws_vpc_id                 = module.vpc.aws_vpc["id"]
  security_group_rule_egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = -1
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
  security_group_rule_ingress = [
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["192.168.0.0/16", "172.16.0.0/16", "10.0.0.0/8"]
    }
  ]
}

module "aws_network_interface_public" {
  source                        = "../modules/aws/network_interface"
  aws_interface_create_eip      = true
  aws_interface_private_ips     = ["10.64.18.10"]
  aws_interface_security_groups = [module.aws_security_group_public.aws_security_group["id"]]
  aws_interface_subnet_id       = module.subnet.aws_subnets[format("%s-sn-workload", var.site_name)]["id"]
}

module "workload" {
  depends_on = [module.site]
  source                  = "../modules/aws/ec2"
  aws_ec2_instance_name   = format("%s-ec2-workload", var.site_name)
  aws_ec2_instance_type   = "t3.micro"
  aws_ec2_instance_script = {
    actions = [
      format("chmod +x /tmp/%s", var.aws_ec2_instance_script_file_name),
      format("sudo /tmp/%s", var.aws_ec2_instance_script_file_name)
    ]
    template_data = var.instance_template_data
  }
  aws_ec2_instance_script_template = var.aws_ec2_instance_script_template_file_name
  aws_ec2_instance_script_file     = var.aws_ec2_instance_script_file_name
  aws_az_name                      = var.aws_az_name
  aws_region                       = var.aws_region
  ssh_private_key_file             = var.ssh_private_key_file
  ssh_public_key_file              = var.ssh_public_key_file
  template_output_dir_path         = local.template_output_dir_path
  template_input_dir_path          = local.template_input_dir_path
  aws_ec2_network_interfaces       = [
    {
      device_index         = 0
      network_interface_id = module.aws_network_interface_public.aws_network_interface["id"]
    }
  ]
  aws_ec2_instance_custom_data_dirs = [
    {
      name        = "instance_script"
      source      = "${local.template_output_dir_path}/${var.aws_ec2_instance_script_file_name}"
      destination = format("/tmp/%s", var.aws_ec2_instance_script_file_name)
    }
  ]
  custom_tags = var.custom_tags
}