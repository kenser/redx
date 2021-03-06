lapis = require "lapis"

lapis_config = require "lapis.config"

lapis_config.config "production", ->
  session_name "redx_session"
  secret config.cookie_secret

lapis_config.config "development", ->
  session_name "redx_session"
  secret config.cookie_secret

process_request = (request) ->
    frontend = redis.fetch_frontend(request, config.max_path_length)
    if frontend == nil
        ngx.req.set_header("X-Redx-Frontend-Cache-Hit", "false")
    else
        ngx.req.set_header("X-Redx-Frontend-Cache-Hit", "true")
        ngx.req.set_header("X-Redx-Frontend-Name", frontend['frontend'])
        ngx.req.set_header("X-Redx-Backend-Name", frontend['backend'])
        backend = redis.fetch_backend(frontend['backend'])
        session = {
            frontend: frontend['frontend'],
            backend: frontend['backend'],
            servers: backend[1],
            config: backend[2],
            server: nil
        }
        if session['servers'] == nil
            ngx.req.set_header("X-Redx-Backend-Cache-Hit", "false")
        else
            -- run pre plugins
            for plugin in *plugins
                if (plugin['plugin']().pre)
                    response = plugin['plugin']().pre(request, session, plugin['param'])
                    if response != nil
                        return response

            -- run balance plugins
            for plugin in *plugins
                if (plugin['plugin']().balance)
                    session['servers'] = plugin['plugin']().balance(request, session, plugin['param'])
                    if type(session['servers']) == 'string'
                        session['server'] = session['servers']
                        break
                    elseif type(session['servers']['address']) == 'string'
                        session['server'] = session['servers']['address']
                        break
                    elseif #session['servers'] == 1
                        session['server'] = session['servers'][1]['address']
                        break
                    elseif session['servers'] == nil or #session['servers'] == 0
                        -- all servers were filtered out, do not proxy
                        session['server'] = nil
                        break

            -- run post plugin 
            for plugin in *plugins
                if (plugin['plugin']().post)
                    response = plugin['plugin']().post(request, session, plugin['param'])
                    if response != nil
                        return response

            if session['server'] != nil
                ngx.req.set_header("X-Redx-Backend-Cache-Hit", "true")
                ngx.req.set_header("X-Redx-Backend-Server", session['server'])
                library.log("SERVER: " .. session['server'])
                ngx.var.upstream = session['server']
    return nil

process_response = (response) ->
    if response
        response = {} unless type(response) == 'table' -- we only accept tables as the response, enforcing here
        response['status'] = 500 unless response['status'] -- default status
        response['message'] = "Unknown failure." unless response['message'] -- default message
        if response['content_type']
            ngx.header["Content-type"] = response['content_type']
        else
            ngx.header["Content-type"] = "text/plain"
        ngx.status = response['status']
        ngx.say(response['message'])
        ngx.exit(response['status'])
    else
        return layout: false

class extends lapis.Application

    '/': =>
        process_response(process_request(@))

    default_route: =>
        process_response(process_request(@))
