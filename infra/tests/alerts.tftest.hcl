mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "azapi" {}
mock_provider "azuread" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "http" {}

variables {
  environment_name            = "test"
  subscription_id             = "00000000-0000-0000-0000-000000000000"
  location                    = "francecentral"
  tags                        = ""
  deployer_ip                 = "192.0.2.1"
  alert_email                 = ""
  critical_job_deadline_hours = 1
}

run "alert_resources_without_email" {
  command = plan

  assert {
    condition     = length(azurerm_monitor_scheduled_query_rules_alert_v2.alerts) == 5
    error_message = "All five scheduled query alerts must be planned."
  }

  assert {
    condition     = alltrue([for alert in values(azurerm_monitor_scheduled_query_rules_alert_v2.alerts) : alert.skip_query_validation])
    error_message = "Scheduled query rules must be created even before their tables exist."
  }

  assert {
    condition     = length(azurerm_monitor_action_group.alerts.email_receiver) == 0
    error_message = "An empty ALERT_EMAIL must not configure an email receiver."
  }

  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.alerts["critical_job_deadline"].criteria[0].query, "OperationName == \"WorkflowRunCompleted\"")
    error_message = "The critical job alert must count completed workflow runs, not action rows."
  }

  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.alerts["workflow_failed"].criteria[0].query, "OperationName == \"WorkflowRunCompleted\"")
    error_message = "The workflow failure alert must count completed workflow runs, not action rows."
  }

  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.alerts["hybrid_job_stuck"].criteria[0].query, "arg_max(TimeGenerated, ResultType) by JobId_g")
    error_message = "The hybrid-job alert must evaluate each job's latest Automation status."
  }

  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.alerts["partner_connection_errors"].severity == 2
    error_message = "Partner connection alerts must use severity 2."
  }

  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.alerts["critical_job_deadline"].criteria[0].query, "ago(1h)")
    error_message = "The critical job alert must default to a one-hour deadline."
  }

  assert {
    condition     = length(jsondecode(file("${path.root}/workbook.json")).items) == 7
    error_message = "The workbook must contain a correlation ID parameter and six monitoring views."
  }
}

run "alert_resources_with_email" {
  command = plan

  variables {
    alert_email = "alerts@example.invalid"
  }

  assert {
    condition     = length(azurerm_monitor_action_group.alerts.email_receiver) == 1
    error_message = "A configured ALERT_EMAIL must create one email receiver."
  }

  assert {
    condition     = azurerm_monitor_action_group.alerts.email_receiver[0].email_address == "alerts@example.invalid"
    error_message = "The action group must use the configured alert email address."
  }
}
