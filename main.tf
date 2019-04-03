resource "aws_iam_role" "role" {
  name               = "IamRole-${local.name}"
  description        = "Role for the ${var.full_name} in ${var.env_name} environment"
  assume_role_policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":[\"s3.amazonaws.com\",\"ec2.amazonaws.com\"]},\"Action\":\"sts:AssumeRole\"}]}"
}

resource "aws_iam_role_policy_attachment" "attach" {
  count      = "${length(var.iam_policies)}"
  role       = "${aws_iam_role.role.name}"
  policy_arn = "${element(var.iam_policies,count.index)}"
}

resource "aws_iam_instance_profile" "profile" {
  depends_on = ["aws_iam_role_policy_attachment.attach"]
  name       = "${aws_iam_role.role.name}"
  role       = "${aws_iam_role.role.name}"
}

resource "aws_launch_configuration" "lc" {
  name_prefix          = "${local.hostname}-"
  image_id             = "${data.aws_ami.image.id}"
  instance_type        = "${var.instance_type}"
  key_name             = "${var.key_name}"
  security_groups      = ["${aws_security_group.sg.id}"]
  user_data            = "${base64encode(data.template_file.userdata.rendered)}"
  iam_instance_profile = "${aws_iam_instance_profile.profile.name}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "asg" {
  name                      = "${aws_launch_configuration.lc.name}"
  vpc_zone_identifier       = ["${var.subnet_ids}"]
  max_size                  = "${var.asg_max_size}"
  min_size                  = "${var.asg_min_size}"
  desired_capacity          = "${var.asg_desired_size}"
  health_check_grace_period = 300
  health_check_type         = "EC2"
  default_cooldown          = 300
  launch_configuration      = "${aws_launch_configuration.lc.name}"
  target_group_arns         = ["${element(concat(aws_lb_target_group.tg.*.id, list("")),0)}"]
  wait_for_capacity_timeout = "10m"
  termination_policies      = ["OldestInstance", "OldestLaunchConfiguration"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${local.name}l"
    propagate_at_launch = "True"
  }

  provisioner "local-exec" {
    interpreter = ["python", "-c"]
    command     = "${local.health_script}"
  }
}

resource "aws_lb_target_group" "tg" {
  count       = "${var.lb_http_listener == "" && var.lb_https_listener == "" ? 0 : 1}"
  name_prefix = "${local.name}-"
  port        = "${var.service_port}"
  protocol    = "HTTP"
  vpc_id      = "${data.aws_subnet.sn.vpc_id}"
  slow_start  = 30

  health_check {
    path     = "${var.lb_health_check_path}"
    port     = "${var.lb_health_check_port == 0 ? var.service_port : var.lb_health_check_port}"
    protocol = "HTTP"
  }
}

resource "aws_lb_listener_rule" "http" {
  count        = "${var.lb_http_listener == "" ? 0 : 1}"
  listener_arn = "${var.lb_http_listener}"

  "action" {
    target_group_arn = "${aws_lb_target_group.tg.id}"
    type             = "forward"
  }

  "condition" {
    field  = "path-pattern"
    values = ["/${var.short_name}/*"]
  }
}

resource "aws_lb_listener_rule" "https" {
  count        = "${var.lb_https_listener == "" ? 0 : 1}"
  listener_arn = "${var.lb_https_listener}"

  "action" {
    target_group_arn = "${aws_lb_target_group.tg.id}"
    type             = "forward"
  }

  "condition" {
    field  = "path-pattern"
    values = ["/${var.short_name}/*"]
  }
}

resource "aws_security_group" "sg" {
  name_prefix = "${local.name}-SG-"
  description = "Security group to associate with ${var.full_name} servers in ${var.env_name} environment"
  vpc_id      = "${data.aws_subnet.sn.vpc_id}"

  tags {
    Name = "${local.name}-SG"
  }
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "allow_icmp_10" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "icmp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "allow_ssh_10" {
  count             = "${var.for_windows ? 0 : 1}"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "allow_rdp_10" {
  count             = "${var.for_windows}"
  type              = "ingress"
  from_port         = 3389
  to_port           = 3389
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "allow_winrm_10" {
  count             = "${var.for_windows}"
  type              = "ingress"
  from_port         = 5985
  to_port           = 5986
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "allow_service_10" {
  type              = "ingress"
  from_port         = "${var.service_port}"
  to_port           = "${var.service_port}"
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "allow_health_10" {
  count             = "${var.lb_health_check_port != 0 && var.lb_health_check_port != var.service_port ? 1 : 0}"
  type              = "ingress"
  from_port         = "${var.lb_health_check_port}"
  to_port           = "${var.lb_health_check_port}"
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}

// followed the doc: https://www.consul.io/docs/agent/options.html#ports-used
resource "aws_security_group_rule" "allow_consul1_10" {
  count             = "${var.enable_consul}"
  type              = "ingress"
  from_port         = 8300
  to_port           = 8302
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "allow_consul2_10" {
  count             = "${var.enable_consul}"
  type              = "ingress"
  from_port         = 8301
  to_port           = 8302
  protocol          = "udp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "allow_consul3_10" {
  count             = "${var.enable_consul}"
  type              = "ingress"
  from_port         = 8500
  to_port           = 8500
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = "${aws_security_group.sg.id}"
}