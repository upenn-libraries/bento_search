require 'test_helper'

# Need ActionView so we have a rails view_context available
# at `view` to test with. 
class DecoratorBaseTest < ActionView::TestCase
  class Base
    def foo
      "foo"
    end
    
    def bar
      "bar"
    end
  end
  
  class SpecificDecorator < BentoSearch::DecoratorBase
    def foo
      "Extra #{super}"
    end
    
    def new_method
      "new_method"
    end
    
    def make_br_with_helper
      _h.tag("br")
    end    
  end
  
  
  def setup
    @base = Base.new
    @decorated = SpecificDecorator.new(@base, view )
  end
  
  def test_pass_through_methods    
    assert_equal "bar", @decorated.bar
  end
  
  def test_decorator_can_add_method
    assert_equal "new_method", @decorated.new_method
  end
  
  def test_override_with_super
    assert_equal "Extra foo", @decorated.foo
  end
  
        
  def test_can_access_view_context_method
    assert_equal tag("br"), @decorated.make_br_with_helper
  end  
  
end
