package osu

import "../af"
import "core:math"
import "core:math/linalg"


/**
    Code taken from peppy's C# example: https://gist.github.com/peppy/1167470 linked to from 
    I've heard it is a bit hard to reproduce, so I've kept it almost verbatim.

    It only works if all objects have had their end_positions and end_times recalculated, using recalculate_object_values for example
**/
recalculate_stack_counts :: proc(beatmap: ^Beatmap) {
    objects := beatmap.hit_objects

    preempt := get_preempt(beatmap)
    STACK_LENIENCE :: 3

    for i := len(objects) - 1; i > 0; i -= 1 {
        if objects[i].type == .Spinner {
            continue
        }

        n := i

        /* We should check every note which has not yet got a stack.
         * Consider the case we have two interwound stacks and this will make sense.
         * 
         * o <-1      o <-2
         *  o <-3      o <-4
         * 
         * We first process starting from 4 and handle 2,
         * then we come backwards on the i loop iteration until we reach 3 and handle 1.
         * 2 and 1 will be ignored in the i loop because they already have a stack value.
         */

        if (objects[i].stack_count != 0) {
            continue
        }

        /* If this object is a hitcircle, then we enter this "special" case.
         * It either ends with a stack of hitcircles only, or a stack of hitcircles that are underneath a slider.
         * Any other case is handled by the "is Slider" code below this.
         */
        if (objects[i].type == .Circle) {
            last_this_stack := i
            for n > 0 {
                n -= 1

                if (objects[n].type == .Spinner) {
                    continue
                }

                // HitObjectSpannable spanN = objects[n] as HitObjectSpannable;
                preempt := get_preempt(beatmap)
                if (objects[last_this_stack].start_time - f64(preempt * beatmap.StackLeniency) >
                       objects[n].end_time) {
                    //We are no longer within stacking range of the previous object.
                    break
                }

                /* This is a special case where hticircles are moved DOWN and RIGHT (negative stacking) if they are under the *last* slider in a stacked pattern.
                 *    o==o <- slider is at original location
                 *        o <- hitCircle has stack of -1
                 *         o <- hitCircle has stack of -2
                 */
                if objects[n].type == .Slider &&
                   (linalg.length(
                               objects[n].end_position - objects[last_this_stack].start_position,
                           ) <
                           STACK_LENIENCE) {
                    offset := objects[last_this_stack].stack_count - objects[n].stack_count + 1
                    for j in n + 1 ..= i {
                        //For each object which was declared under this slider, we will offset it to appear *below* the slider end (rather than above).
                        if linalg.length(objects[n].end_position - objects[j].start_position) <
                           STACK_LENIENCE {
                            objects[j].stack_count -= offset
                        }
                    }

                    //We have hit a slider.  We should restart calculation using this as the new base.
                    //Breaking here will mean that the slider still has StackCount of 0, so will be handled in the i-outer-loop.
                    break
                }

                if (linalg.length(
                           objects[n].start_position - objects[last_this_stack].start_position,
                       ) <
                       STACK_LENIENCE) {
                    //Keep processing as if there are no sliders.  If we come across a slider, this gets cancelled out.
                    //NOTE: Sliders with start positions stacking are a special case that is also handled here.

                    objects[n].stack_count = objects[last_this_stack].stack_count + 1
                    last_this_stack = n
                }
            }
        } else if (objects[i].type == .Slider) {
            /* We have hit the first slider in a possible stack.
             * From this point on, we ALWAYS stack positive regardless.
             */
            last_this_stack := i
            for (n > 0) {
                n -= 1

                if (objects[n].type == .Spinner) {
                    continue
                }


                preempt := get_preempt(beatmap)
                if (objects[last_this_stack].start_time - f64(preempt * beatmap.StackLeniency) >
                       objects[n].end_time) {
                    //We are no longer within stacking range of the previous object.
                    break
                }

                if (linalg.length(
                           objects[n].end_position - objects[last_this_stack].start_position,
                       ) <
                       STACK_LENIENCE) {
                    objects[n].stack_count = objects[last_this_stack].stack_count + 1
                    last_this_stack = n
                }
            }
        }
    }
}


// This only works if you have already ran calculate_stack_counts on the beatmap
get_hit_object_stack_offset :: proc(hit_object: HitObject, circle_radius: f32) -> Vec2 {
    stack_offset := (circle_radius / 10) * Vec2{1, 1}
    return -(f32(hit_object.stack_count) * stack_offset)
}
