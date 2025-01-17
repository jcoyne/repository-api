# frozen_string_literal: true

Rails.application.configure do
  config.lograge.enabled = Rails.env.production?
  config.lograge.base_controller_class = ['ActionController::API', 'ActionController::Base']
  config.lograge.ignore_actions = ['OkComputer::OkComputerController#show']
end
