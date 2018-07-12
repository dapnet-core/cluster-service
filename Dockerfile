FROM elixir:latest

COPY . /app

WORKDIR /app

RUN mix local.hex --force
RUN mix local.rebar --force
RUN mix deps.get

CMD ["./run.sh"]
