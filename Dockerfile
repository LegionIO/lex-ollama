FROM legionio/legion

COPY . /usr/src/app/lex-ollama

WORKDIR /usr/src/app/lex-ollama
RUN bundle install
