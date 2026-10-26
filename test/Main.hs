{-# LANGUAGE ForeignFunctionInterface #-}
-- static-pie の確認用。
-- 最後の行に rts のシンボル hs_init の実行時アドレスを出す。
-- PIE が ASLR で動いていれば、実行のたびに値が変わる。
module Main (main) where

import qualified Data.Map.Strict as M
import Foreign.Ptr (FunPtr, castFunPtrToPtr)

foreign import ccall "&hs_init" hsInitAddr :: FunPtr (IO ())

main :: IO ()
main = do
  let m = M.fromList [(i, i * i) | i <- [1 .. 10 :: Integer]]
  print (M.foldr (+) 0 m)
  print (2 ^ (200 :: Int) :: Integer)
  putStrLn ("hs_init at " ++ show (castFunPtrToPtr hsInitAddr))
