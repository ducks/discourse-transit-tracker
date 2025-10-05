# frozen_string_literal: true

DiscourseTransitTracker::Engine.routes.draw { get "/" => "board#respond" }

Discourse::Application.routes.draw do
  mount DiscourseTransitTracker::Engine, at: "/board"

  get "/transit/board" => "transit_board#index"
  get "/transit/proxy" => "transit_proxy#index"
end
