# Copyright (C) 2012-2025 Zammad Foundation, https://zammad-foundation.org/

Zammad::Application.routes.draw do
  api_path = Rails.configuration.api_path

  match api_path + '/channels_discord',                         to: 'channels_discord#index',    via: :get
  match api_path + '/channels_discord',                         to: 'channels_discord#add',      via: :post
  match api_path + '/channels_discord/:id',                     to: 'channels_discord#update',   via: :put
  match api_path + '/channels_discord_webhook/:callback_token', to: 'channels_discord#webhook',  via: :post
  match api_path + '/channels_discord_disable',                 to: 'channels_discord#disable',  via: :post
  match api_path + '/channels_discord_enable',                  to: 'channels_discord#enable',   via: :post
  match api_path + '/channels_discord',                         to: 'channels_discord#destroy',  via: :delete

end
