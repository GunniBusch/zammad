# Copyright (C) 2012-2025 Zammad Foundation, https://zammad-foundation.org/

require 'discordrb'

class DiscordHelper

  attr_accessor :client

  def self.check_token(token)
    bot = Discordrb::Bot.new(token: token)
    bot.run :async
    bot.ready do
      bot.stop
    end
    bot
  rescue
    raise Exceptions::UnprocessableEntity, 'invalid api token'
  end

  def self.set_webhook(token, callback_url)
    if callback_url.match?(%r{^http://}i)
      raise Exceptions::UnprocessableEntity, __('The Discord integration can only be configured on systems using the HTTPS protocol.')
    end

    bot = Discordrb::Bot.new(token: token)
    bot.run :async
    bot.ready do
      bot.stop
    end
    true
  rescue
    raise Exceptions::UnprocessableEntity, __('The webhook could not be saved by Discord, seems to be an invalid URL.')
  end

  def self.create_or_update_channel(token, params, channel = nil)
    bot = check_token(token)

    if !channel && bot_duplicate?(bot.profile.id)
      raise Exceptions::UnprocessableEntity, __('This bot already exists.')
    end

    if params[:group_id].blank?
      raise Exceptions::UnprocessableEntity, __("The required parameter 'group_id' is missing.")
    end

    group = Group.find_by(id: params[:group_id])
    if !group
      raise Exceptions::UnprocessableEntity, __("The required parameter 'group_id' is invalid.")
    end

    callback_token = if Rails.env.test?
                       'callback_token'
                     else
                       SecureRandom.urlsafe_base64(10)
                     end

    callback_url = "#{Setting.get('http_type')}://#{Setting.get('fqdn')}/api/v1/channels_discord_webhook/#{callback_token}?bid=#{bot.profile.id}"
    set_webhook(token, callback_url)

    if !channel
      channel = bot_by_bot_id(bot.profile.id)
      if !channel
        channel = Channel.new
      end
    end
    channel.area = 'Discord::Bot'
    channel.options = {
      bot:            {
        id:         bot.profile.id,
        username:   bot.profile.username,
        discriminator: bot.profile.discriminator,
      },
      callback_token: callback_token,
      callback_url:   callback_url,
      api_token:      token,
      welcome:        params[:welcome],
      goodbye:        params[:goodbye],
    }
    channel.group_id = group.id
    channel.active = true
    channel.save!
    channel
  end

  def self.bot_duplicate?(bot_id, channel_id = nil)
    Channel.where(area: 'Discord::Bot').each do |channel|
      next if !channel.options
      next if !channel.options[:bot]
      next if !channel.options[:bot][:id]
      next if channel.options[:bot][:id] != bot_id
      next if channel.id.to_s == channel_id.to_s

      return true
    end
    false
  end

  def self.bot_by_bot_id(bot_id)
    Channel.where(area: 'Discord::Bot').each do |channel|
      next if !channel.options
      next if !channel.options[:bot]
      next if !channel.options[:bot][:id]
      return channel if channel.options[:bot][:id].to_s == bot_id.to_s
    end
    nil
  end

  def self.message_id(params)
    message_id = params[:id]
    "#{message_id}@discord"
  end

  def initialize(token)
    @token = token
  end

  def message(channel_id, message)
    return if Rails.env.test?

    bot = Discordrb::Bot.new(token: @token)
    bot.run :async
    bot.send_message(channel_id, message)
    bot.stop
  end

  def user(params)
    {
      id:         params[:author][:id],
      username:   params[:author][:username],
      discriminator: params[:author][:discriminator],
    }
  end

  def to_user(params)
    Rails.logger.debug { 'Create user from message...' }
    Rails.logger.debug { params.inspect }

    message_user = user(params)

    auth = Authorization.find_by(uid: message_user[:id], provider: 'discord')

    login = "#{message_user[:username]}##{message_user[:discriminator]}"
    user_data = {
      login:     login,
      firstname: message_user[:username],
    }
    if auth
      user = User.find(auth.user_id)
      user.update!(user_data)
    else
      user_data[:note] = "Discord @#{message_user[:username]}"
      user_data[:active]   = true
      user_data[:role_ids] = Role.signup_role_ids
      user                 = User.create(user_data)
    end

    auth_data = {
      uid:      message_user[:id],
      username: login,
      user_id:  user.id,
      provider: 'discord'
    }
    if auth
      auth.update!(auth_data)
    else
      Authorization.create(auth_data)
    end

    user
  end

  def to_ticket(params, user, group_id, channel)
    UserInfo.current_user_id = user.id

    Rails.logger.debug { 'Create ticket from message...' }
    Rails.logger.debug { params.inspect }
    Rails.logger.debug { user.inspect }
    Rails.logger.debug { group_id.inspect }

    title = params[:content]
    if title.length > 60
      title = "#{title[0, 60]}..."
    end

    state_ids        = Ticket::State.where(name: %w[closed merged removed]).pluck(:id)
    possible_tickets = Ticket.where(customer_id: user.id).where.not(state_id: state_ids).reorder(:updated_at)
    ticket           = possible_tickets.find_each.find { |possible_ticket| possible_ticket.preferences[:channel_id] == channel.id }

    if ticket
      if ticket.title == '-'
        ticket.title = title
      end
      new_state = Ticket::State.find_by(default_create: true)
      if ticket.state_id != new_state.id
        ticket.state = Ticket::State.find_by(default_follow_up: true)
      end
      ticket.save!
      return ticket
    end

    ticket = Ticket.new(
      group_id:    group_id,
      title:       title,
      state_id:    Ticket::State.find_by(default_create: true).id,
      priority_id: Ticket::Priority.find_by(default_create: true).id,
      customer_id: user.id,
      preferences: {
        channel_id: channel.id,
        discord:    {
          bid:     params['bid'],
          channel_id: params[:channel_id]
        }
      },
    )
    ticket.save!
    ticket
  end

  def to_article(params, user, ticket, channel, article = nil)
    if article
      Rails.logger.debug { 'Update article from message...' }
    else
      Rails.logger.debug { 'Create article from message...' }
    end
    Rails.logger.debug { params.inspect }
    Rails.logger.debug { user.inspect }
    Rails.logger.debug { ticket.inspect }

    UserInfo.current_user_id = user.id

    if article
      article.preferences[:edited_message] = {
        message:   {
          created_at: params[:timestamp],
          message_id: params[:id],
          from:       params[:author],
        },
        update_id: params[:id],
      }
    else
      article = Ticket::Article.new(
        ticket_id:   ticket.id,
        type_id:     Ticket::Article::Type.find_by(name: 'discord personal-message').id,
        sender_id:   Ticket::Article::Sender.find_by(name: 'Customer').id,
        from:        user(params)[:username],
        to:          "@#{channel[:options][:bot][:username]}",
        message_id:  DiscordHelper.message_id(params),
        internal:    false,
        preferences: {
          message:   {
            created_at: params[:timestamp],
            message_id: params[:id],
            from:       params[:author],
          },
          update_id: params[:id],
        }
      )
    end

    article.content_type = 'text/plain'
    article.body = params[:content]
    article.save!
    article
  end

  def to_group(params, group_id, channel)
    Rails.logger.debug { 'import message' }

    return if !params[:edited_message] && Ticket::Article.exists?(message_id: DiscordHelper.message_id(params))

    if params[:edited_message]
      article = Ticket::Article.find_by(message_id: DiscordHelper.message_id(params))
      return if !article

      params[:message] = params[:edited_message]
      user = to_user(params)
      to_article(params, user, article.ticket, channel, article)
      return article
    end

    ticket = nil

    Transaction.execute(reset_user_id: true, context: 'discord') do
      user   = to_user(params)
      ticket = to_ticket(params, user, group_id, channel)
      to_article(params, user, ticket, channel)
    end

    ticket
  end

  def from_article(article)
    Rails.logger.debug { "Create discord personal message from article to '#{article[:to]}'..." }

    message = {}
    message
  end
end
