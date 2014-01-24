# -*- encoding: utf-8 -*-

require 'MeCab'
require 'fluent-logger'
require 'json'
require 'singleton'

class SingletonFluentd
  include Singleton

  def initialize
    @fluentd = Fluent::Logger::FluentLogger.open('depression',
      host = 'localhost', port = 9999)
  end

  def fluentd
    @fluentd
  end
end

class SingletonMecab
  include Singleton

  def initialize
    @mecab = MeCab::Tagger.new("-Ochasen")
  end

  def mecab
    @mecab
  end
end

class SingletonDic
  include Singleton

  def initialize
    dic_file = File.join(File.dirname(__FILE__), '..', '..', 'pn_ja.dic')
    @dic = Array.new
    open(dic_file) do |file|
      file.each_line do |line|
        @dic << line.force_encoding("utf-8").chomp.split(':')
      end
    end
  end

  def dic
    @dic
  end
end

class StoriesController < ApplicationController
  def new
    @story = Story.new

    respond_to do |format|
      format.html
      format.json { render json: @story }
    end
  end

  def show
    @story = Story.find(params[:id])

    respond_to do |format|
      format.html
      format.json { render json: @story }
    end
  end

  def create
    @mecab   = SingletonMecab.instance.mecab
    @dic     = SingletonDic.instance.dic

    @story = Story.new(story_params)
    @story.text = params[:story][:text].truncate_screen_width(1000, suffix = "")
    @scores = Array.new

    depression
    result = '判定結果は「' + @story.classify + '」です'

    respond_to do |format|
      session[:result]        = result
      session[:text]          = @story.text.truncate_screen_width(500, suffix = "...")
      session[:classify]      = @story.classify
      session[:total_score]   = @story.total_score
      session[:scores]        = @story.scores.truncate_screen_width(500, suffix = "...")

      if Rails.env.production?
        @fluentd = SingletonFluentd.instance.fluentd
        @fluentd.post('record', {
          :text          => @story.text,
          :classify      => @story.classify,
          :total_score   => @story.total_score,
          :scores        => @story.scores
        })
      end

      if @story.save
        notice = "#{result}"
        format.html { redirect_to root_path,
          notice: notice }
        format.json { render json: @story, status: :created, location: @story }
      else
        format.html { render action: "new" }
        format.json { render json: @story.errors, status: :unprocessable_entity }
      end
    end
  end

  def index
    depressions = Story.where(classify: '鬱ツイート')
    @stories = depressions.page(params[:page]).order(id: :desc)
    @all = Story.count
    @depressions_count = depressions.count
    @depression_rate = @depressions_count / @all.to_f * 100

    respond_to do |format|
      format.html
      format.json { render json: @stories }
    end
  end

  private

  def set_story
    @story = Story.find(params[:id])
  end

  def story_params
    params.require(:story).permit(:text)
  end

  def depression
    score = 0.0
    word_count = 0
    parse_to_node(@story.text).each {|word|
      if i = @dic.assoc(word)
        word_count += 1
        @scores << i
        score += i[3].to_f
      end
    }
    if word_count > 1
      @story.total_score = (score / word_count) ** 3
      @story.classify = @story.total_score > -0.20 ? '普通のツイート' : '鬱ツイート'
      @story.scores = JSON.generate(@scores)
    else
      @story.total_score = 0.0
      @story.classify = '判定不能'
      @story.scores = '語彙が少なすぎて判定できません。もう少し語彙を増やしてください。'
    end
  end

  def parse_to_node(string)
    node = @mecab.parseToNode(string)
    nouns = []
    while node
      nouns.push(node.surface.force_encoding("utf-8"))
      node = node.next
    end
    nouns
  end
end

class String
  def truncate_screen_width(width , suffix = "...")
    i = 0
    self.each_char.inject(0) do |c, x|
      c += x.ascii_only? ? 1 : 2
      i += 1
      next c if c < width
      return self[0 , i] + suffix
    end
    return self
  end
end
