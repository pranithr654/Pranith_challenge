# Provision a web server instance using the latest Ubuntu 16.04 on a
# t2.micro node with an AWS Tag naming it "web-server"
provider "aws"{
    region = "us-east-1"
    access_key = "<Place Your KEy>"
    secret_key = "<Place Your KEy>"

    # Make it faster by skipping something
  skip_get_ec2_platforms      = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_credentials_validation = true
  skip_requesting_account_id  = true
}
#######
resource "aws_vpc" "default" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags {
    Name = "tf_test"
  }
}

resource "aws_subnet" "tf_test_subnet" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = true

  tags {
    Name = "tf_test_subnet"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.default.id}"

  tags {
    Name = "tf_test_ig"
  }
}

resource "aws_route_table" "r" {
  vpc_id = "${aws_vpc.default.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }

  tags {
    Name = "aws_route_table"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = "${aws_subnet.tf_test_subnet.id}"
  route_table_id = "${aws_route_table.r.id}"
}

# Our default security group to access
# the instances over SSH and HTTP
resource "aws_security_group" "default" {
  name        = "instance_sg"
  description = "Used in the terraform"
  vpc_id      = "${aws_vpc.default.id}"

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Our elb security group to access
# the ELB over HTTP
resource "aws_security_group" "elb" {
  name        = "elb_sg"
  description = "Used in the terraform"

  vpc_id = "${aws_vpc.default.id}"

  # HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ensure the VPC has an Internet gateway or this step will fail
  depends_on = ["aws_internet_gateway.gw"]
}

resource "tls_private_key" "ca" {
    algorithm = "RSA"
    rsa_bits = 2048
}

resource "tls_self_signed_cert" "example" {
  key_algorithm   = "${tls_private_key.ca.algorithm}"
  private_key_pem = "${tls_private_key.ca.private_key_pem}"
  

  subject {
    common_name  = "example.com"
    organization = "ACME Examples, Inc"
  }

  validity_period_hours = 12

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_iam_server_certificate" "test_cert" {
  name_prefix      = "example-cert"
  #certificate_body = "${file("mycert.pem")}"
  certificate_body = "${tls_self_signed_cert.example.cert_pem}"
  private_key      = "${tls_private_key.ca.private_key_pem}"

  lifecycle {
    create_before_destroy = true
  }
}



resource "aws_elb" "web" {
  name = "example-elb"

  # The same availability zone as our instance
  subnets = ["${aws_subnet.tf_test_subnet.id}"]

  security_groups = ["${aws_security_group.elb.id}"]

  listener {
    instance_port     = 443
    instance_protocol = "https"
    lb_port           = 443
    lb_protocol       = "https"
    ssl_certificate_id = "${aws_iam_server_certificate.test_cert.arn}"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 30
  }

  # The instance is registered automatically

  instances                   = ["${aws_instance.web_server.id}"]
  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400
}


#########
# Get the AWS Ubuntu image
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }
  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

# Deploy ssh key for instance access
resource "aws_key_pair" "deployer" {
  key_name = "web_server_kp" 
  public_key = "${file("~/.ssh/id_rsa.pub")}"
  
}

# Create web server
resource "aws_instance" "web_server" {
    ami = "${data.aws_ami.ubuntu.id}"
    vpc_security_group_ids = ["${aws_security_group.default.id}"]
    subnet_id              = "${aws_subnet.tf_test_subnet.id}"
    instance_type = "t2.micro"
    key_name      = "web_server_kp"
    tags {
        Name = "web-server"
    }

      connection {
    type        = "ssh"
    user         = "ubuntu"
    private_key  = "${file("~/.ssh/id_rsa")}"
  }


 provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install apache2 -y",
      "sudo systemctl enable apache2",
      "sudo systemctl start apache2",
      "sudo chmod 777 /var/www/html/index.html"
    ]

  
  }

  provisioner "file" {
    source = "index.html"
    destination = "/var/www/html/index.html"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo chmod 644 /var/www/html/index.html"
    ]
  }

  # Save the public IP for testing
  provisioner "local-exec" {
    command = "echo ${aws_instance.web_server.public_ip} > public-ip.txt"
  }

}

output "public_ip" {
  value = "${aws_instance.web_server.public_ip}"
}
